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
  echo "$d"
}

# run_case <dir> [extra env assignments...] — รันสคริปต์ด้วยคำสั่งปลอม เก็บ exit code ใน $d/exit
run_case() {
  local d="$1"
  shift
  env DORMI_BACKUP_ENV="$d/env" \
    DORMI_BACKUP_DIR="$d/backups" \
    DORMI_DUMP_CMD="printf 'PGDMP-fake-dump'" \
    DORMI_VERIFY_CMD="true" \
    DORMI_UPLOAD_CMD="$d/fake-upload" \
    "$@" bash "$SCRIPT" > "$d/log" 2>&1
  echo $? > "$d/exit"
}

# uploader ปลอม: จด path ที่ได้รับ แล้วจบด้วย exit code ที่กำหนด
fake_uploader() { # fake_uploader <dir> <exit-code>
  printf '#!/usr/bin/env bash\necho "$1" >> "%s/uploaded"\nexit %s\n' "$1" "$2" > "$1/fake-upload"
  chmod +x "$1/fake-upload"
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

# ── cleanup ──
d="$(sandbox)"; fake_uploader "$d" 0
touch -d '4 days ago' "$d/backups/dormi-old.dump"
touch -d '1 day ago' "$d/backups/dormi-recent.dump"
run_case "$d"
check cleanup "4-day-old dump deleted" "$([ ! -e "$d/backups/dormi-old.dump" ]; echo $?)"
check cleanup "1-day-old dump kept" "$([ -e "$d/backups/dormi-recent.dump" ]; echo $?)"

echo "test-db-dump: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
