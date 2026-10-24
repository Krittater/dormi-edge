#!/usr/bin/env bash
# ตรวจว่า pii.alloy ตัด PII จริง: test/sample.log → loki.process (pii.alloy) → loki.echo
#   bash deploy/monitoring/test/run-redact-check.sh
# รันได้ทั้งบนเครื่อง dev (Docker Desktop / git-bash) และบน server · ไม่แตะ container อื่น
# ผ่าน = พิมพ์ REDACT_CHECK_PASS และ exit 0 · ไม่ผ่าน = บอกข้อที่ล้ม และ exit 1
set -Eeuo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${ALLOY_IMAGE:-$(sed -n 's/^ *image: *\(grafana\/alloy:[^ ]*\).*/\1/p' "$HERE/docker-compose.yml" | head -n1)}
NAME=obstest-redact-$$
MOUNT=$HERE
command -v cygpath >/dev/null 2>&1 && MOUNT=$(cygpath -w "$HERE")   # git-bash บน Windows

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

MSYS_NO_PATHCONV=1 docker run -d --name "$NAME" -v "$MOUNT:/m:ro" "$IMAGE" \
  run --storage.path=/tmp/alloy /m/test/redact-check.alloy >/dev/null

# บรรทัด log_statement ของ Postgres (statement/execute/bind/parse/duration + DETAIL: parameters) ถูกทิ้งทั้งบรรทัดใน pii.alloy → ไม่ถึง loki.echo
DROPPED=$(grep -cE 'LOG:  ([0-9A-Z]{5}: )?(statement|execute|bind|parse|duration)|DETAIL:  ([0-9A-Z]{5}: )?parameters:' "$HERE/test/sample-postgres.log" || true)
EXPECTED=$(( $(cat "$HERE/test/sample.log" "$HERE/test/sample-postgres.log" | grep -c .) - DROPPED ))
out=""
for _ in $(seq 1 30); do
  out=$(docker logs "$NAME" 2>&1 | grep 'component_id=loki.echo.out' || true)
  [[ $(printf '%s\n' "$out" | grep -c 'received log entry' || true) -ge $EXPECTED ]] && break
  sleep 1
done
printf '%s\n' "$out"

fail=0
must()    { grep -qF -- "$1" <<<"$out" || { echo "FAIL: ไม่พบ   $1"; fail=1; }; }
mustnot() { ! grep -qF -- "$1" <<<"$out" || { echo "FAIL: ยังหลุด $1"; fail=1; }; }

[[ $(printf '%s\n' "$out" | grep -c 'received log entry' || true) -eq "$EXPECTED" ]] || { echo "FAIL: ไม่ได้ $EXPECTED บรรทัด"; fail=1; }
must '[email]'
must '[phone]'
must '[national-id]'
must '1.2.3.0'
must '5.6.7.0'
must '2001:db8:1::'
must '\"uri\":\"/x\"'
must '\"referer\":\"https://app.dormi-linkandrent.com/login\"'
must 'feature=\"auth\"'
must 'feature=\"roomTypes\"'   # feature camelCase ต้องได้เป็น label (regex รับ A-Z)
must 'status=\"409\"'
must 'entry="2026-10-24T20:30:01Z OK daily/x 123"'
mustnot 'a@b.com'
mustnot 'c%40d'
mustnot '1.2.3.4'
mustnot '5.6.7.8'
mustnot ':2::3'
mustnot '?email'
mustnot '?u='
mustnot '0812345678'
mustnot '234-5678'
mustnot '123-4567'
mustnot '67890-12'
mustnot '1234567890123'
mustnot '\x1b'
# nginx error log (ข้อความอิสระ ไม่ใช่ JSON)
must 'client: 11.22.33.0'
must 'request: \"GET /reset HTTP/1.1\"'
must 'upstream: \"http://172.18.0.0:3000/reset\"'
must 'referrer: \"https://app.dormi-linkandrent.com/login\"'
mustnot '11.22.33.44'
mustnot 'token='
mustnot 'tok123secret'
mustnot 'refsecret'
# ข้อความอิสระใน path (B1): percent-encoded → [enc] · ไทยดิบ → [text] · อีเมล %40 → [email] · id/uuid/สแลช ASCII คงไว้
must '\"uri\":\"/apartments/[enc]/rooms\"'
must '\"referer\":\"https://app.dormi-linkandrent.com/apartments/[enc]/rooms\"'
must '\"uri\":\"/apartments/[text]/rooms\"'
must '\"uri\":\"/auth/reset/[email]/step\"'
must '\"uri\":\"/apartments/0b1c2d3e-aaaa-bbbb-cccc-1234567890ab/rooms/42\"'
must '\"referer\":\"https://app.dormi-linkandrent.com/apartments/0b1c2d3e/rooms\"'
must 'request: \"GET /apartments/[enc]/rooms HTTP/1.1\"'
must 'upstream: \"http://172.18.0.0:3000/apartments/[enc]/rooms\"'
must 'referrer: \"https://app.dormi-linkandrent.com/apartments/[enc]/rooms\"'
must 'request: \"GET /apartments/[enc]/[email]/[text] HTTP/1.1\"'
mustnot '%E0'
mustnot '%B8'
mustnot '\xE0'
mustnot 'ภาษา'
mustnot 'pathmail'
mustnot 'zz%40'
# เบอร์แบบ 66 นำหน้า ไม่มี +
must 'send failed for [phone]'
mustnot '66812345678'
# Postgres DETAIL (ชื่อ / ยอดเงินในแถว)
must 'Failing row contains [row].'
must '\"apartmentId\")=[key] already exists.'
must 'violates unique constraint \"UQ_users_name\"'
mustnot 'somchai.j'
mustnot '12500.00'
mustnot '000000000001'
must 'STATEMENT:  [statement]'
mustnot 'stmtname.x'
mustnot '4321.50'
mustnot 'contsecret.y'
must '[continued]'
# Postgres ข้อความ error อื่น ๆ ที่มีค่าที่ผู้ใช้พิมพ์
must 'invalid input syntax for type uuid: \"[value]\" at character 45'
must 'invalid input value for enum user_role_enum: \"[value]\"'
must 'Token \"[value]\" is invalid.'
must 'CONTEXT:  [context]'
must 'QUERY:  [query]'
must 'argument types: \"[value]\"'
must 'relation \"job_runs\" does not exist at character 73'
mustnot 'uuidsecret'
mustnot 'enumsecret'
mustnot 'tokensecret'
mustnot 'ctxsecret'
mustnot 'qrysecret'
mustnot 'hintsecret'
# Postgres log_statement=mod: prod ตั้งไว้ → ทุก INSERT/UPDATE/DELETE ลง log พร้อมค่าจริง → ต้องไม่ออกนอกเครื่องเลย
mustnot '1500.00'
mustnot 'สมชาย'
mustnot '0812345678'
mustnot 'INSERT INTO'
mustnot 'RETURNING'
mustnot 'parameters:'
mustnot 'UPDATE users'
mustnot 'durexecsecret'
mustnot 'durstmtsecret'
mustnot 'namedexecsecret'
mustnot 'paramsecret'
mustnot 'bindsecret'
mustnot 'parsesecret'
mustnot 'durbindsecret'
mustnot 'durparsesecret'
mustnot 'multilinesecret'
mustnot 'SET note'
# log_error_verbosity=verbose พิมพ์ SQLSTATE นำหน้า (`LOG:  00000: statement:`) → ต้องถูกทิ้งเช่นกัน
mustnot 'verbosestmtsecret'
mustnot 'verboseexecsecret'
mustnot 'verboseparamsecret'
mustnot 'verbosedursecret'
# บรรทัดต่อ (tab) ของ statement ที่ถูกทิ้ง ยังต้องถูกปิดเป็น [continued] (ดู mustnot 'SET note' ข้างบน)
# negative: log ปกติของ Postgres ต้องยังมาถึง (ไม่ใช่ทิ้งทั้ง container) — LOG ที่ไม่ใช่ SQL + ข้อความ ERROR (ชนิด error ยังอ่านออก)
must 'LOG:  checkpoint starting: time'
must 'ERROR:  null value in column \"amount\" of relation \"incomes\" violates not-null constraint'
# negative: stage ของ Postgres ต้องไม่แตะ container อื่น
must '[Audit] STATEMENT:  keep-me-statement'
must 'entry="\tkeep-me-tab: \"keep-me-quoted\""'
# negative: กฎทิ้ง log_statement ต้องจำกัดเฉพาะ container postgres (บรรทัดนี้อยู่ใน sample.log ที่ไม่มี label container)
must 'keep-me-nonpg'

if [[ $fail -ne 0 ]]; then
  echo REDACT_CHECK_FAIL
  exit 1
fi
echo REDACT_CHECK_PASS
