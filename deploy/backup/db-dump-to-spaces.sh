#!/usr/bin/env bash
# dump ฐานข้อมูล Dormi วันละครั้ง → อัปขึ้น DigitalOcean Spaces (bucket ลบไฟล์เก่ากว่า 14 วันเอง)
#
# ติดตั้งบน server เป็น /usr/local/bin/dormi-db-dump · cron: deploy/backup/dormi-db-backup.cron
# key อยู่ใน /root/.config/dormi-db-backup.env (chmod 600) — ไม่อยู่ใน repo:
#   SPACES_KEY=...  SPACES_SECRET=...  SPACES_BUCKET=dormi-db-backups  SPACES_REGION=sgp1
#
# exit: 0 สำเร็จ · 2 ตั้งค่าไม่ครบ · 3 dump พัง/อ่านไม่ได้ · 4 อัปโหลดไม่สำเร็จ
# ★ ทุกเคสที่ล้มเขียน "FAILED: ..." ลง log และไม่แตะ last-success — monitoring อ่านไฟล์นั้นได้
# ★ DORMI_* override ไว้ให้ test-db-dump.sh ใช้คำสั่งปลอมแทนของจริง
set -euo pipefail

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() { log "FAILED: $1"; exit "$2"; }

ENV_FILE="${DORMI_BACKUP_ENV:-/root/.config/dormi-db-backup.env}"
DIR="${DORMI_BACKUP_DIR:-/var/backups/dormi}"
KEEP_LOCAL_MINUTES=$((3 * 24 * 60)) # เก็บสำเนาในเครื่อง 3 วัน เผื่อ Spaces ล่ม

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
object="dormi-$stamp.dump"
file="$DIR/$object"

# ── 1) dump ──
if [ -n "${DORMI_DUMP_CMD:-}" ]; then
  dump() { bash -c "$DORMI_DUMP_CMD"; }
else
  dump() { docker exec dormi_postgres sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"'; }
fi
if ! dump > "$file"; then
  rm -f "$file"
  fail "pg_dump" 3
fi

# ── 2) ตรวจว่าไฟล์อ่านได้จริง ก่อนอัป (กันไฟล์ครึ่งเดียว) ──
if [ -n "${DORMI_VERIFY_CMD:-}" ]; then
  verify() { bash -c "$DORMI_VERIFY_CMD"; }
else
  verify() { docker exec -i dormi_postgres pg_restore --list > /dev/null; }
fi
if ! verify < "$file"; then
  fail "dump unreadable ($file kept for inspection)" 3
fi

# ── 3) อัปโหลด ──
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
      "https://${SPACES_BUCKET}.${SPACES_REGION}.digitaloceanspaces.com/daily/$2" > /dev/null
}
if ! upload "$file" "$object"; then
  fail "upload $object" 4
fi

# ── 4) สำเร็จ ──
log "OK $object $(stat -c %s "$file")"
date -u +%Y-%m-%dT%H:%M:%SZ > "$DIR/last-success"
find "$DIR" -maxdepth 1 -name 'dormi-*.dump' -mmin "+$KEEP_LOCAL_MINUTES" -delete
