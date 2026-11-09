#!/usr/bin/env bash
# S2 Task 10 — ตรวจ routing ของ edge ก่อน/หลังสลับ authority ด้วย upstream จำลอง (ไม่แตะ container จริงใด ๆ)
#   bash scripts/test-platform-routing.sh
# ต้องมี image ตาม FROM ของ Dockerfile (ตอนนี้ nginx:1.30-alpine) · สร้าง network/container ชั่วคราวชื่อ dormi-rt-* แล้วลบทิ้งเสมอ
set -euo pipefail
export MSYS_NO_PATHCONV=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# ใช้ image เดียวกับ edge จริง — อัปเกรด Dockerfile แล้ว test ตามเอง
IMAGE=$(sed -n 's/^FROM[[:space:]]\{1,\}//p' "$ROOT/Dockerfile" | head -1)
RUN="dormi-rt-$$"
NET="$RUN-net"
WORK="$(mktemp -d)"
host_path() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }
cleanup() {
  docker rm -f "$RUN-edge" "$RUN-api" "$RUN-admin" "$RUN-web" "$RUN-landing" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
dump() { docker logs "$RUN-edge" 2>&1 | tail -20; }

# upstream จำลอง: ตอบชื่อตัวเอง + method + uri (ชื่อ service ตรงกับที่ edge ใช้)
docker network create "$NET" >/dev/null
# client_max_body_size 0 = upstream รับทุกขนาด → 413 ที่เห็นในเทสต์มาจาก edge เท่านั้น
for svc in api admin web landing; do
  mkdir -p "$WORK/$svc"
  printf 'server { listen 3000; client_max_body_size 0; location / { return 200 "%s $request_method $request_uri\\n"; } }\n' "$svc" > "$WORK/$svc/default.conf"
  docker run -d --name "$RUN-$svc" --network "$NET" --network-alias "dormi-$svc" \
    -v "$(host_path "$WORK/$svc"):/etc/nginx/conf.d:ro" "$IMAGE" >/dev/null
done

# edge: config ของ repo · snippets คัดลอกมาเพื่อสลับ authority ได้โดยไม่แก้ไฟล์จริง
cp -r "$ROOT/nginx/snippets" "$WORK/snippets"
# checkout บน Windows อาจเป็น CRLF — shebang ที่ลงท้ายด้วย CR ทำให้ entrypoint หา script ไม่เจอ
sed 's/\r$//' "$ROOT/docker-entrypoint.d/10-init-dummy-cert.sh" > "$WORK/10-init-dummy-cert.sh"
chmod +x "$WORK/10-init-dummy-cert.sh"
docker run -d --name "$RUN-edge" --network "$NET" \
  -v "$(host_path "$ROOT/nginx/nginx.conf"):/etc/nginx/nginx.conf:ro" \
  -v "$(host_path "$ROOT/nginx/projects"):/etc/nginx/projects:ro" \
  -v "$(host_path "$WORK/snippets"):/etc/nginx/snippets" \
  -v "$(host_path "$WORK/10-init-dummy-cert.sh"):/docker-entrypoint.d/10-init-dummy-cert.sh:ro" \
  "$IMAGE" sh -c 'apk add --no-cache openssl >/dev/null 2>&1; exec /docker-entrypoint.sh nginx -g "daemon off;"' >/dev/null

for _ in $(seq 1 60); do
  docker exec "$RUN-edge" curl -skf --resolve dormi-api.dormi-linkandrent.com:443:127.0.0.1 https://dormi-api.dormi-linkandrent.com/whoami >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$RUN-edge" nginx -t || { dump; exit 1; }

fail=0
# req <host> <method> <path> → "<status> <ตัวตอบ>" · curl ไม่ follow redirect (301 = ล้ม)
req() {
  local host="$1" method="$2" path="$3" out
  out=$(docker exec "$RUN-edge" curl -sk -X "$method" -H 'content-type: application/json'     $([ "$method" = POST ] && echo "--data {}")     --resolve "$host:443:127.0.0.1" -w '
%{http_code}' "https://$host$path" 2>&1 || true)
  local status body
  status=$(echo "$out" | tail -1)
  body=$(echo "$out" | grep -E '^(api|admin|web|landing) ' | head -1)
  echo "$status ${body:-}"
}
expect() {
  local want="$1" got
  shift
  got=$(req "$@")
  if [[ "$got" == "$want"* ]]; then echo "ok   $* → $got"; else echo "FAIL $* → '$got' (ต้องการ '$want')"; fail=1; fi
}
# upload <host> <path> → status ของ POST body 20 MB (ไฟล์สร้างใน container edge ครั้งเดียว)
docker exec "$RUN-edge" sh -c 'head -c 20971520 /dev/zero > /tmp/body-20m'
upload_expect() {
  local want="$1" host="$2" path="$3" got
  got=$(docker exec "$RUN-edge" curl -sk -o /dev/null -w '%{http_code}' -X POST \
    -H 'content-type: application/octet-stream' --data-binary @/tmp/body-20m \
    --resolve "$host:443:127.0.0.1" "https://$host$path" 2>&1 || true)
  if [[ "$got" == "$want" ]]; then echo "ok   upload 20MB $host $path → $got"; else echo "FAIL upload 20MB $host $path → '$got' (ต้องการ '$want')"; fail=1; fi
}
API=dormi-api.dormi-linkandrent.com
ADMIN=admin-api.dormi-linkandrent.com
WEB=app.dormi-linkandrent.com
LANDING=dormi-linkandrent.com
ALL_HOSTS=("$API" "$ADMIN" "$WEB" "$LANDING")

echo "── ก่อน cutover: เจ้าของเดิม (backend) ──"
expect "200 api GET /admin/dashboard" "$API" GET /admin/dashboard
expect "200 api GET /public/plans" "$API" GET /public/plans
expect "200 api GET /auth/me" "$API" GET /auth/me
for h in "${ALL_HOSTS[@]}"; do expect "404" "$h" POST /internal/platform/v1/owners/context; done
expect "404" "$LANDING" GET /internal/logo.png
expect "200 landing GET /" "$LANDING" GET /

echo "── พฤติกรรมของ main ที่ merge ผิดแล้วหายเงียบ ──"
# /api/internal/ ของ admin เดิม (78f2b80) — ทุก method / ตัวพิมพ์ใหญ่
expect "404" "$ADMIN" GET /api/internal/anything
expect "404" "$ADMIN" POST /API/Internal/anything
expect "404" "$ADMIN" GET /api/internal
expect "200 admin GET /api/admin/users" "$ADMIN" GET /api/admin/users
# upload 50m เฉพาะ route อัปโหลดของ dormi-api · ที่อื่น 2m (http) → 413
upload_expect 200 "$API" /apartments/a1/me/payment-slips
upload_expect 200 "$API" /APARTMENTS/a1/payment-accounts/qr-scan/
upload_expect 200 "$API" /apartments/a1/utility-meter-groups/g1/cycles/c1/document
upload_expect 413 "$API" /apartments/a1/rooms
upload_expect 413 "$ADMIN" /api/admin/users
upload_expect 200 "$API" /apartments/a1/files
upload_expect 200 "$API" /apartments/a1/files/
upload_expect 200 "$API" /admin/platform-invoices/i1/payments
upload_expect 413 "$API" /apartments/a1/files/extra
upload_expect 413 "$API" /admin/platform-invoices/i1
# rate limit ยังถูกใช้ครบทุกโซน (ไม่ใช่แค่ประกาศ)
for zone in api_auth_login api_auth_other web_auth_pages landing_per_ip; do
  if docker exec "$RUN-edge" nginx -T 2>/dev/null | grep -Eq "^[[:space:]]*limit_req zone=$zone "; then
    echo "ok   limit_req zone=$zone ถูกใช้"
  else
    echo "FAIL limit_req zone=$zone หาย"; fail=1
  fi
done
# login ถูก limit จริง: burst 30 → ยิง 40 ครั้งติดต้องเจอ 429 (รูปแบบ JSON ของ edge)
hits=$(docker exec "$RUN-edge" sh -c 'for i in $(seq 1 40); do curl -sk -o /dev/null -w "%{http_code}\n" -X POST --resolve dormi-api.dormi-linkandrent.com:443:127.0.0.1 https://dormi-api.dormi-linkandrent.com/Auth/Login/; done' | grep -c '^429$' || true)
if [[ "$hits" -gt 0 ]]; then echo "ok   /Auth/Login/ ถูก rate limit ($hits/40 ได้ 429)"; else echo "FAIL /Auth/Login/ ไม่ถูก rate limit"; fail=1; fi

echo "── หลังสลับ authority ──"
sed -i 's/^set \$platform_pool dormi_api_pool;/set $platform_pool dormi_admin_pool;/' "$WORK/snippets/platform-authority.conf"
grep -q 'dormi_admin_pool;' "$WORK/snippets/platform-authority.conf"
docker exec "$RUN-edge" nginx -t || { dump; exit 1; }
docker exec "$RUN-edge" nginx -s reload
sleep 1
expect "200 admin POST /admin/customers" "$API" POST /admin/customers
expect "200 admin GET /admin/customers/x/overview?limit=2" "$API" GET "/admin/customers/x/overview?limit=2"
expect "200 admin GET /public/plans" "$API" GET /public/plans
expect "200 admin GET /public/chat-links/abc12345/visit" "$API" GET /public/chat-links/abc12345/visit
expect "200 api POST /auth/register" "$API" POST /auth/register
expect "200 api GET /public/other" "$API" GET /public/other
expect "200 api GET /apartments" "$API" GET /apartments
expect "200 admin GET /api/admin/users" "$ADMIN" GET /api/admin/users
for h in "${ALL_HOSTS[@]}"; do expect "404" "$h" GET /internal/platform/v1/operations/x; done
upload_expect 200 "$API" /apartments/a1/me/payment-slips
expect "404" "$ADMIN" GET /api/internal/anything

echo "── ตัวพิมพ์ใหญ่ (Express จับ route ไม่สนตัวพิมพ์) ──"
expect "200 admin GET /Admin/plans" "$API" GET /Admin/plans
expect "200 admin POST /ADMIN/customers" "$API" POST /ADMIN/customers
expect "200 admin GET /Public/Chat-Links/abc12345/visit" "$API" GET /Public/Chat-Links/abc12345/visit
for h in "${ALL_HOSTS[@]}"; do expect "404" "$h" GET /Internal/platform/v1/operations/x; done

echo "── maintenance: ปิด writes ──"
expect "200 api POST /auth/register" "$API" POST /auth/register
sed -i 's/^set \$maintenance 0;/set $maintenance 1;/' "$WORK/snippets/maintenance.conf"
grep -q '^set \$maintenance 1;' "$WORK/snippets/maintenance.conf"
docker exec "$RUN-edge" nginx -t || { dump; exit 1; }
docker exec "$RUN-edge" nginx -s reload
sleep 1
expect "503" "$API" POST /auth/register
expect "503" "$API" POST /admin/customers
expect "503" "$API" POST /admin/auth/login
expect "503" "$ADMIN" POST /api/admin/users
expect "200 api POST /auth/login" "$API" POST /auth/login
expect "200 api POST /auth/logout" "$API" POST /auth/logout
expect "200 admin GET /admin/customers" "$API" GET /admin/customers
expect "200 api GET /apartments" "$API" GET /apartments
expect "200 web GET /" "$WEB" GET /

echo "── maintenance + authority=backend (ขั้น 1–7 ของ runbook / rollback ก่อนเปิด writes) ──"
sed -i 's/^set \$platform_pool dormi_admin_pool;/set $platform_pool dormi_api_pool;/' "$WORK/snippets/platform-authority.conf"
grep -q 'dormi_api_pool;' "$WORK/snippets/platform-authority.conf"
docker exec "$RUN-edge" nginx -t || { dump; exit 1; }
docker exec "$RUN-edge" nginx -s reload
sleep 1
expect "200 api GET /admin/customers" "$API" GET /admin/customers
expect "503" "$API" POST /admin/customers
expect "503" "$API" POST /apartments/a1/me/payment-slips

echo "exit=$fail"
exit $fail
