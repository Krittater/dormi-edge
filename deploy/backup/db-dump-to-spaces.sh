#!/usr/bin/env bash
# dump ฐานข้อมูล Dormi + tar รูปสลิป/ไฟล์ (docker volume) วันละครั้ง → อัปขึ้น DigitalOcean Spaces
# (bucket ลบไฟล์เก่ากว่า 14 วันเอง — lifecycle rule ครอบทั้ง bucket ไม่จำกัด prefix: terraform/spaces.tf)
# object: daily/dormi-<db>-<stamp>.dump · files/<UTC date>.tar.gz
#
# ติดตั้งบน server เป็น /usr/local/bin/dormi-db-dump · cron: deploy/backup/dormi-db-backup.cron
# key อยู่ใน /root/.config/dormi-db-backup.env (chmod 600) — ไม่อยู่ใน repo:
#   SPACES_KEY=...  SPACES_SECRET=...  SPACES_BUCKET=dormi-db-backups  SPACES_REGION=sgp1
#
# exit: 0 สำเร็จ · 2 ตั้งค่าไม่ครบ · 3 dump พัง/อ่านไม่ได้ · 4 อัปโหลด DB ไม่สำเร็จ · 5 ขั้นตอนไฟล์ล้ม
# ★ ทุกเคสที่ล้มเขียน "FAILED: ..." ลง log และไม่แตะ last-success — monitoring อ่านไฟล์นั้นได้
# ★ บรรทัดสุดท้าย "<ISO-UTC> DONE <unix ts>" เขียนเฉพาะเมื่อ DB + ไฟล์สำเร็จหมด (alert ใช้ดูว่ารอบล่าสุดครบ)
#   ไฟล์ล้ม = DB ที่อัปสำเร็จยังขึ้น "OK ..." และ last-success ตามเดิม แต่ไม่มี DONE และ exit 5
# ★ DORMI_* override ไว้ให้ test-db-dump.sh ใช้คำสั่งปลอมแทนของจริง
#   DORMI_FILES_VOLUME = volume ที่เก็บรูปสลิป (ค่าจริงบน prod = dormi_files_data · อย่าใช้ docker_dormi_files_data ที่ว่างเปล่า)
set -euo pipefail

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() { log "FAILED: $1"; exit "$2"; }

ENV_FILE="${DORMI_BACKUP_ENV:-/root/.config/dormi-db-backup.env}"
DIR="${DORMI_BACKUP_DIR:-/var/backups/dormi}"
KEEP_LOCAL_MINUTES=$((3 * 24 * 60)) # เก็บสำเนาในเครื่อง 3 วัน เผื่อ Spaces ล่ม
FILES_VOLUME="${DORMI_FILES_VOLUME:-dormi_files_data}"
FILES_IMAGE="${DORMI_FILES_IMAGE:-alpine:3.20}"

[ -r "$ENV_FILE" ] || fail "missing env file $ENV_FILE" 2
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a
for name in SPACES_KEY SPACES_SECRET SPACES_BUCKET SPACES_REGION; do
  [ -n "${!name:-}" ] || fail "missing $name" 2
done

mkdir -p "$DIR"
stamp="$(date -u +%Y%m%d-%H%M)"

# ── 0) ฐานข้อมูลที่ต้อง dump: ทุกฐานที่เปิดรับการเชื่อมต่อ ยกเว้น template และ postgres ──
# ★ datallowconn: ฐานที่ถูกปิดไว้ (เช่น dormi_v2_failed_… ที่เหลือจาก migration พัง) pg_dump เข้าไม่ได้
# ★ ไม่ใช่แค่ POSTGRES_DB — instance เดียวกันมี dormi_admin (ระบบแอดมิน) ด้วย ฐานที่เพิ่มทีหลังติดมาเอง
if [ -n "${DORMI_DB_LIST:-}" ]; then
  dbs="$DORMI_DB_LIST"
elif ! dbs="$(docker exec dormi_postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT datname FROM pg_database WHERE NOT datistemplate AND datallowconn AND datname <> '"'"'postgres'"'"' ORDER BY 1"')"; then
  fail "list databases" 3
fi
[ -n "$dbs" ] || fail "list databases (empty)" 3

if [ -n "${DORMI_DUMP_CMD:-}" ]; then
  dump() { bash -c "$DORMI_DUMP_CMD" _ "$1"; }
else
  dump() { docker exec dormi_postgres sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$1"' _ "$1"; }
fi
# ★ --file=/dev/null อ่าน data ทุกบล็อกจริง — --list อ่านแค่สารบัญที่อยู่หัวไฟล์ ไฟล์ที่ขาดท้ายก็ผ่าน
if [ -n "${DORMI_VERIFY_CMD:-}" ]; then
  verify() { bash -c "$DORMI_VERIFY_CMD"; }
else
  verify() { docker exec -i dormi_postgres pg_restore --file=/dev/null; }
fi
# upload <file> <object key เต็ม เช่น daily/x.dump หรือ files/2026-01-01.tar.gz>
# ★ key/secret ส่งให้ curl ทาง stdin (--config -) ไม่ใช่ argv — ไม่โผล่ใน `ps` และไม่ลง log
upload() {
  if [ -n "${DORMI_UPLOAD_CMD:-}" ]; then
    "$DORMI_UPLOAD_CMD" "$1" "$2"
    return
  fi
  printf 'user = "%s:%s"\n' "$SPACES_KEY" "$SPACES_SECRET" |
    curl -fsS --config - \
      --aws-sigv4 "aws:amz:${SPACES_REGION}:s3" \
      -T "$1" \
      "https://${SPACES_BUCKET}.${SPACES_REGION}.digitaloceanspaces.com/$2" > /dev/null
}

# ── ทีละฐาน: dump → ตรวจว่าอ่านได้ครบ → อัป · ฐานไหนพัง = ทั้งรอบล้ม (ไม่เขียน last-success) ──
for db in $dbs; do
  object="dormi-$db-$stamp.dump"
  file="$DIR/$object"
  if ! dump "$db" > "$file"; then
    rm -f "$file"
    fail "pg_dump $db" 3
  fi
  if ! verify < "$file"; then
    fail "dump unreadable $db ($file kept for inspection)" 3
  fi
  if ! upload "$file" "daily/$object"; then
    fail "upload $object" 4
  fi
  log "OK $object $(stat -c %s "$file")"
done

date -u +%Y-%m-%dT%H:%M:%SZ > "$DIR/last-success"
find "$DIR" -maxdepth 1 \( -name 'dormi-*.dump' -o -name 'dormi-files-*.tar.gz' \) -mmin "+$KEEP_LOCAL_MINUTES" -delete

# ── ไฟล์: tar volume รูปสลิป → ตรวจ gzip อ่านได้ครบ → อัป files/<UTC date>.tar.gz ──
# ★ ขั้นนี้ล้ม = DB ข้างบนยังอัปสำเร็จแล้ว (log OK ไว้) แต่ไม่พิมพ์ DONE และ exit 5
# ★ `docker run -v <ชื่อไม่มี>` สร้าง volume ว่างเงียบ ๆ → ตรวจว่ามี volume จริงก่อน ไม่งั้นได้ backup เปล่าที่ดูเหมือนสำเร็จ
# ★ mount :ro + --network none — อ่านอย่างเดียว ไม่แตะรูปจริง
fdate="$(date -u +%Y-%m-%d)"
fobject="files/$fdate.tar.gz"
ffile="$DIR/dormi-files-$fdate.tar.gz"
if ! docker volume inspect "$FILES_VOLUME" > /dev/null 2>&1; then
  fail "files: docker volume $FILES_VOLUME not found" 5
fi
if ! docker run --rm --name "dormi-backup-tar-$$-$(date +%s)" --network none -v "$FILES_VOLUME:/d:ro" "$FILES_IMAGE" tar czf - -C /d . > "$ffile.part"; then
  rm -f "$ffile.part"
  fail "files: tar $FILES_VOLUME" 5
fi
# ★ gzip -t อ่านทั้งไฟล์ (เช็ก CRC) — จับไฟล์ที่ขาดท้าย · ไฟล์ว่าง (0 byte) ไม่ผ่านด้วย
if [ ! -s "$ffile.part" ] || ! gzip -t "$ffile.part" 2> /dev/null; then
  rm -f "$ffile.part"
  fail "files: archive empty or unreadable" 5
fi
mv "$ffile.part" "$ffile"
if ! upload "$ffile" "$fobject"; then
  fail "files: upload $fobject" 5
fi
log "OK $fobject $(stat -c %s "$ffile")"

log "DONE $(date -u +%s)"
