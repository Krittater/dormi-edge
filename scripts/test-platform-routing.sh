#!/usr/bin/env bash
# S2 Task 10 — ตรวจ routing ของ edge ก่อน/หลังสลับ authority ด้วย upstream จำลอง (ไม่แตะ container จริงใด ๆ)
#   bash scripts/test-platform-routing.sh
# ต้องมี image nginx:1.28-alpine (base ของ Dockerfile) · สร้าง network/container ชั่วคราวชื่อ dormi-rt-* แล้วลบทิ้งเสมอ
set -euo pipefail
export MSYS_NO_PATHCONV=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE=nginx:1.28-alpine
RUN="dormi-rt-$$"
NET="$RUN-net"
WORK="$(mktemp -d)"
host_path() { if command -v cygpath >/dev/null; then cygpath -w "$1"; else echo "$1"; fi; }
cleanup() {
  docker rm -f "$RUN-edge" "$RUN-api" "$RUN-admin" "$RUN-web" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT
dump() { docker logs "$RUN-edge" 2>&1 | tail -20; }

# upstream จำลอง: ตอบชื่อตัวเอง + method + uri (ชื่อ service ตรงกับที่ edge ใช้)
docker network create "$NET" >/dev/null
for svc in api admin web; do
  mkdir -p "$WORK/$svc"
  printf 'server { listen 3000; location / { return 200 "%s $request_method $request_uri\\n"; } }\n' "$svc" > "$WORK/$svc/default.conf"
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
  body=$(echo "$out" | grep -E '^(api|admin|web) ' | head -1)
  echo "$status ${body:-}"
}
expect() {
  local want="$1" got
  shift
  got=$(req "$@")
  if [[ "$got" == "$want"* ]]; then echo "ok   $* → $got"; else echo "FAIL $* → '$got' (ต้องการ '$want')"; fail=1; fi
}
API=dormi-api.dormi-linkandrent.com
ADMIN=admin-api.dormi-linkandrent.com
WEB=app.dormi-linkandrent.com

echo "── ก่อน cutover: เจ้าของเดิม (backend) ──"
expect "200 api GET /admin/dashboard" "$API" GET /admin/dashboard
expect "200 api GET /public/plans" "$API" GET /public/plans
expect "200 api GET /auth/me" "$API" GET /auth/me
for h in "$API" "$ADMIN" "$WEB"; do expect "404" "$h" POST /internal/platform/v1/owners/context; done

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
for h in "$API" "$ADMIN" "$WEB"; do expect "404" "$h" GET /internal/platform/v1/operations/x; done

echo "── ตัวพิมพ์ใหญ่ (Express จับ route ไม่สนตัวพิมพ์) ──"
expect "200 admin GET /Admin/plans" "$API" GET /Admin/plans
expect "200 admin POST /ADMIN/customers" "$API" POST /ADMIN/customers
expect "200 admin GET /Public/Chat-Links/abc12345/visit" "$API" GET /Public/Chat-Links/abc12345/visit
for h in "$API" "$ADMIN" "$WEB"; do expect "404" "$h" GET /Internal/platform/v1/operations/x; done

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

exit $fail
