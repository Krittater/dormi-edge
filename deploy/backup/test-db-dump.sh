#!/usr/bin/env bash
# ทดสอบ db-dump-to-spaces.sh แบบไม่แตะของจริง — แทน pg_dump / pg_restore / curl ด้วยคำสั่งปลอม
# รัน: bash deploy/backup/test-db-dump.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/db-dump-to-spaces.sh"
SECRET="s3cr3t-value-never-in-log"
pass=0
fail=0

check() { # check <case> <description> <condition-exit-code>
  if [ "$3" -eq 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "  FAIL [$1] $2"; fi
}

# เตรียม sandbox ใหม่ทุกเคส — echo path ของโฟลเดอร์ออกมา
sandbox() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/backups"
  printf 'SPACES_KEY=test-key\nSPACES_SECRET=%s\nSPACES_BUCKET=test-bucket\nSPACES_REGION=sgp1\n' "$SECRET" > "$d/env"
  fake_docker "$d"
  echo "$d"
}

# run_case <dir> [extra env assignments...] — รันสคริปต์ด้วยคำสั่งปลอม เก็บ exit code ใน $d/exit
run_case() {
  local d="$1"
  shift
  # dump ปลอมได้ชื่อ DB เป็น $1 · verify ปลอมยอมรับเฉพาะไฟล์ที่มี END (= อ่านได้ครบทั้งไฟล์)
  env DORMI_BACKUP_ENV="$d/env" \
    DORMI_BACKUP_DIR="$d/backups" \
    DORMI_DB_LIST="dormi_v2" \
    DORMI_DUMP_CMD='printf "PGDMP-%s-END" "$1"' \
    DORMI_VERIFY_CMD="grep -q END" \
    DORMI_UPLOAD_CMD="$d/fake-upload" \
    PATH="$d/bin:$PATH" \
    "$@" bash "$SCRIPT" > "$d/log" 2>&1
  echo $? > "$d/exit"
}

# uploader ปลอม: จด "<object key> <path>" ที่ได้รับ (key = $2, path = $1) แล้วจบด้วย exit code ที่กำหนด
# ถ้าระบุ failing-key-prefix: อัปที่ key ขึ้นต้นด้วยค่านั้นจะล้ม (exit 1) ที่เหลือผ่าน
#   → จำลอง "อัป DB ได้ แต่อัปไฟล์ไม่ได้"
fake_uploader() { # fake_uploader <dir> <exit-code> [failing-key-prefix]
  cat > "$1/fake-upload" << EOF
#!/usr/bin/env bash
echo "\$2 \$1" >> "$1/uploaded"
fp="${3:-}"
[ -n "\$fp" ] && case "\$2" in "\$fp"*) exit 1 ;; esac
exit $2
EOF
  chmod +x "$1/fake-upload"
}

# docker ปลอม (อยู่ใน $d/bin ซึ่งอยู่หน้า PATH): จด argument ลง $d/docker-calls
#   volume inspect → exit 0 (หรือ 1 ถ้า FAKE_NO_VOLUME=1)
#   run ...        → พ่น tar.gz ปลอมตาม FAKE_TAR: ok (ค่าเริ่มต้น) | fail | empty | trunc
fake_docker() { # fake_docker <dir>
  mkdir -p "$1/bin"
  cat > "$1/bin/docker" << 'EOF'
#!/usr/bin/env bash
echo "$*" >> "$(dirname "$0")/../docker-calls"
if [ "$1 $2" = "volume inspect" ]; then
  [ "${FAKE_NO_VOLUME:-}" = 1 ] && exit 1
  exit 0
fi
if [ "$1" = run ]; then
  case "${FAKE_TAR:-ok}" in
    ok) printf 'slip-image-bytes' | gzip -c ;;
    fail) printf 'partial'; exit 1 ;;
    empty) ;;
    trunc) printf 'slip-image-bytes' | gzip -c | head -c 10 ;;
  esac
  exit 0
fi
echo "unexpected docker call: $*" >&2
exit 99
EOF
  chmod +x "$1/bin/docker"
}

[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

# ── ok ──
d="$(sandbox)"; fake_uploader "$d" 0; run_case "$d"
check ok "exit 0" "$([ "$(cat "$d/exit")" = 0 ]; echo $?)"
check ok "log has OK dormi-" "$(grep -q 'OK dormi-' "$d/log"; echo $?)"
check ok "last-success written" "$([ -s "$d/backups/last-success" ]; echo $?)"
check ok "uploader got the dump path" "$(grep -q '/dormi-.*\.dump$' "$d/uploaded" 2>/dev/null; echo $?)"
check ok "log lines start with UTC timestamp" "$(grep -vqE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z ' "$d/log"; [ $? -ne 0 ]; echo $?)"
# ── no-secret-in-log (ใช้ log ของเคส ok) ──
check no-secret-in-log "secret never in log" "$(! grep -q "$SECRET" "$d/log"; echo $?)"

# ── missing-secret ──
d="$(sandbox)"; fake_uploader "$d" 0; sed -i '/^SPACES_SECRET=/d' "$d/env"; run_case "$d"
check missing-secret "exit 2" "$([ "$(cat "$d/exit")" = 2 ]; echo $?)"
check missing-secret "log FAILED: missing SPACES_SECRET" "$(grep -q 'FAILED: missing SPACES_SECRET' "$d/log"; echo $?)"
check missing-secret "no upload" "$([ ! -e "$d/uploaded" ]; echo $?)"
check missing-secret "no last-success" "$([ ! -e "$d/backups/last-success" ]; echo $?)"

# ── unreadable-dump ──
d="$(sandbox)"; fake_uploader "$d" 0; run_case "$d" DORMI_VERIFY_CMD="false"
check unreadable-dump "exit 3" "$([ "$(cat "$d/exit")" = 3 ]; echo $?)"
check unreadable-dump "log FAILED: dump unreadable" "$(grep -q 'FAILED: dump unreadable' "$d/log"; echo $?)"
check unreadable-dump "no upload" "$([ ! -e "$d/uploaded" ]; echo $?)"

# ── upload-fails ──
d="$(sandbox)"; fake_uploader "$d" 1; echo "2026-01-01T00:00:00Z" > "$d/backups/last-success"; run_case "$d"
check upload-fails "exit 4" "$([ "$(cat "$d/exit")" = 4 ]; echo $?)"
check upload-fails "log FAILED: upload" "$(grep -q 'FAILED: upload' "$d/log"; echo $?)"
check upload-fails "last-success unchanged" "$([ "$(cat "$d/backups/last-success")" = "2026-01-01T00:00:00Z" ]; echo $?)"
check upload-fails "no DONE" "$(! grep -q ' DONE ' "$d/log"; echo $?)"

# ── cleanup ──
d="$(sandbox)"; fake_uploader "$d" 0
touch -d '4 days ago' "$d/backups/dormi-old.dump"
touch -d '1 day ago' "$d/backups/dormi-recent.dump"
run_case "$d"
check cleanup "4-day-old dump deleted" "$([ ! -e "$d/backups/dormi-old.dump" ]; echo $?)"
check cleanup "1-day-old dump kept" "$([ -e "$d/backups/dormi-recent.dump" ]; echo $?)"

# ── all-dbs: ทุกฐานข้อมูลถูก dump + อัปแยกไฟล์ (เดิม dump แค่ POSTGRES_DB — dormi_admin หลุด) ──
d="$(sandbox)"; fake_uploader "$d" 0; run_case "$d" DORMI_DB_LIST="dormi_v2 dormi_admin"
check all-dbs "exit 0" "$([ "$(cat "$d/exit")" = 0 ]; echo $?)"
check all-dbs "uploaded dormi_v2" "$(grep -q '/dormi-dormi_v2-.*\.dump$' "$d/uploaded" 2>/dev/null; echo $?)"
check all-dbs "uploaded dormi_admin" "$(grep -q '/dormi-dormi_admin-.*\.dump$' "$d/uploaded" 2>/dev/null; echo $?)"
check all-dbs "2 OK lines" "$([ "$(grep -c ' OK dormi-' "$d/log")" = 2 ]; echo $?)"

# ── one-db-fails: ฐานไหนพัง = ทั้งรอบล้ม ไม่ประกาศสำเร็จ ──
d="$(sandbox)"; fake_uploader "$d" 0
run_case "$d" DORMI_DB_LIST="dormi_v2 dormi_admin" DORMI_DUMP_CMD='[ "$1" = dormi_admin ] && exit 1; printf "PGDMP-%s-END" "$1"'
check one-db-fails "exit 3" "$([ "$(cat "$d/exit")" = 3 ]; echo $?)"
check one-db-fails "log FAILED: pg_dump dormi_admin" "$(grep -q 'FAILED: pg_dump dormi_admin' "$d/log"; echo $?)"
check one-db-fails "no last-success" "$([ ! -e "$d/backups/last-success" ]; echo $?)"
check one-db-fails "partial file removed" "$(! ls "$d/backups"/dormi-dormi_admin-*.dump >/dev/null 2>&1; echo $?)"

# ── truncated-dump: pg_dump จบ 0 แต่ไฟล์ขาด → ต้องจับได้ ไม่อัป ──
d="$(sandbox)"; fake_uploader "$d" 0; run_case "$d" DORMI_DUMP_CMD='printf "PGDMP-%s-cut" "$1"'
check truncated-dump "exit 3" "$([ "$(cat "$d/exit")" = 3 ]; echo $?)"
check truncated-dump "log FAILED: dump unreadable" "$(grep -q 'FAILED: dump unreadable' "$d/log"; echo $?)"
check truncated-dump "no upload" "$([ ! -e "$d/uploaded" ]; echo $?)"

# ══ ไฟล์ (รูปสลิป ฯลฯ ใน docker volume) ══
today="$(date -u +%Y-%m-%d)"

# ── files-ok: tar volume → อัป files/<date>.tar.gz → log OK + DONE เป็นบรรทัดสุดท้าย ──
d="$(sandbox)"; fake_uploader "$d" 0; before="$(date -u +%s)"; run_case "$d"; after="$(date -u +%s)"
check files-ok "exit 0" "$([ "$(cat "$d/exit")" = 0 ]; echo $?)"
check files-ok "uploaded key files/$today.tar.gz" "$(grep -q "^files/$today\.tar\.gz " "$d/uploaded" 2>/dev/null; echo $?)"
check files-ok "DB still uploaded under daily/" "$(grep -q '^daily/dormi-dormi_v2-.*\.dump ' "$d/uploaded" 2>/dev/null; echo $?)"
check files-ok "log OK files/<date>.tar.gz <bytes>" "$(grep -qE "^[0-9TZ:-]+ OK files/$today\.tar\.gz [0-9]+$" "$d/log"; echo $?)"
check files-ok "last log line is '<ISO> DONE <unix ts>'" "$(tail -n 1 "$d/log" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z DONE [0-9]+$'; echo $?)"
ts="$(tail -n 1 "$d/log" | awk '{print $3}')"
check files-ok "DONE ts is current unix time" "$([ "${ts:-0}" -ge "$before" ] && [ "${ts:-0}" -le "$((after + 1))" ]; echo $?)"
check files-ok "exactly one DONE line" "$([ "$(grep -c ' DONE ' "$d/log")" = 1 ]; echo $?)"
check files-ok "docker volume checked then mounted read-only (dormi_files_data)" "$(grep -q '^volume inspect dormi_files_data$' "$d/docker-calls" && grep -q '^run .*-v dormi_files_data:/d:ro' "$d/docker-calls"; echo $?)"
check files-ok "all log lines have UTC timestamp" "$(grep -vqE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z ' "$d/log"; [ $? -ne 0 ]; echo $?)"
check files-ok "secret never in log" "$(! grep -q "$SECRET" "$d/log"; echo $?)"
check files-ok "secret never in docker argv" "$(! grep -q "$SECRET" "$d/docker-calls"; echo $?)"

# ── volume-name-override: ชื่อ volume เป็นตัวแปร ──
d="$(sandbox)"; fake_uploader "$d" 0; run_case "$d" DORMI_FILES_VOLUME=other_vol
check volume-override "uses other_vol" "$(grep -q '^run .*-v other_vol:/d:ro' "$d/docker-calls"; echo $?)"

# ── DB สำเร็จ + ไฟล์ล้ม: DB lines คงเดิม แต่ไม่มี DONE และ exit ≠ 0 ──
d="$(sandbox)"; fake_uploader "$d" 0 files/; run_case "$d"
check files-upload-fails "exit 5" "$([ "$(cat "$d/exit")" = 5 ]; echo $?)"
check files-upload-fails "log FAILED: files" "$(grep -q ' FAILED: files' "$d/log"; echo $?)"
check files-upload-fails "DB OK line still logged" "$(grep -q ' OK dormi-dormi_v2-' "$d/log"; echo $?)"
check files-upload-fails "no DONE" "$(! grep -q ' DONE ' "$d/log"; echo $?)"
check files-upload-fails "no OK files line" "$(! grep -q ' OK files/' "$d/log"; echo $?)"
check files-upload-fails "DB last-success still written" "$([ -s "$d/backups/last-success" ]; echo $?)"

d="$(sandbox)"; fake_uploader "$d" 0; run_case "$d" FAKE_TAR=fail
check files-tar-fails "exit 5" "$([ "$(cat "$d/exit")" = 5 ]; echo $?)"
check files-tar-fails "log FAILED: files" "$(grep -q ' FAILED: files' "$d/log"; echo $?)"
check files-tar-fails "files not uploaded" "$(! grep -q '^files/' "$d/uploaded"; echo $?)"
check files-tar-fails "no DONE" "$(! grep -q ' DONE ' "$d/log"; echo $?)"
check files-tar-fails "partial archive removed" "$(! ls "$d/backups"/dormi-files-* >/dev/null 2>&1; echo $?)"

d="$(sandbox)"; fake_uploader "$d" 0; run_case "$d" FAKE_TAR=empty
check files-empty "exit 5" "$([ "$(cat "$d/exit")" = 5 ]; echo $?)"
check files-empty "log FAILED: files" "$(grep -q ' FAILED: files' "$d/log"; echo $?)"
check files-empty "files not uploaded" "$(! grep -q '^files/' "$d/uploaded"; echo $?)"
check files-empty "no DONE" "$(! grep -q ' DONE ' "$d/log"; echo $?)"

d="$(sandbox)"; fake_uploader "$d" 0; run_case "$d" FAKE_TAR=trunc
check files-truncated "exit 5" "$([ "$(cat "$d/exit")" = 5 ]; echo $?)"
check files-truncated "log FAILED: files" "$(grep -q ' FAILED: files' "$d/log"; echo $?)"
check files-truncated "files not uploaded" "$(! grep -q '^files/' "$d/uploaded"; echo $?)"
check files-truncated "no DONE" "$(! grep -q ' DONE ' "$d/log"; echo $?)"

# ── volume ไม่มี: docker run -v จะสร้าง volume ว่างเงียบ ๆ → ต้องตรวจก่อน ไม่งั้นได้ backup เปล่าที่ดูเหมือนสำเร็จ ──
d="$(sandbox)"; fake_uploader "$d" 0; run_case "$d" FAKE_NO_VOLUME=1
check volume-missing "exit 5" "$([ "$(cat "$d/exit")" = 5 ]; echo $?)"
check volume-missing "log FAILED: files ... dormi_files_data" "$(grep -q ' FAILED: files.*dormi_files_data' "$d/log"; echo $?)"
check volume-missing "docker run not called" "$(! grep -q '^run ' "$d/docker-calls"; echo $?)"
check volume-missing "no DONE" "$(! grep -q ' DONE ' "$d/log"; echo $?)"

# ── DB ล้ม = ไม่ถึงขั้นไฟล์ และไม่มี DONE ──
d="$(sandbox)"; fake_uploader "$d" 1; run_case "$d"
check db-upload-fails-no-done "no DONE" "$(! grep -q ' DONE ' "$d/log"; echo $?)"
check db-upload-fails-no-done "files step not attempted" "$(! grep -q '^run ' "$d/docker-calls" 2>/dev/null; echo $?)"

# ── cleanup: สำเนา archive ในเครื่องเก่ากว่า 3 วันถูกลบ ──
d="$(sandbox)"; fake_uploader "$d" 0
touch -d '4 days ago' "$d/backups/dormi-files-old.tar.gz"
touch -d '1 day ago' "$d/backups/dormi-files-recent.tar.gz"
run_case "$d"
check files-cleanup "4-day-old archive deleted" "$([ ! -e "$d/backups/dormi-files-old.tar.gz" ]; echo $?)"
check files-cleanup "1-day-old archive kept" "$([ -e "$d/backups/dormi-files-recent.tar.gz" ]; echo $?)"

echo "test-db-dump: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
