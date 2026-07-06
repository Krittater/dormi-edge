#!/bin/sh
set -eu

# ============================================================
# ออก/ต่ออายุ SAN cert ใบเดียว (edge-dormi) ครอบ "ทุกโดเมน"
# ที่ประกาศไว้ใน nginx/projects/*.conf โดยอัตโนมัติ
#
# → เพิ่ม project ใหม่ = แค่เพิ่มไฟล์ conf แล้วรัน script นี้ (ไม่ต้องพิมพ์โดเมนเอง)
#
# ต้องรันจาก root ของ dormi-edge (ที่มี docker-compose.yml)
# ============================================================

CERT_NAME="edge-dormi"
EMAIL="${CERTBOT_EMAIL:-admin@dormi-linkandrent.com}"

# ดึงทุก server_name (ยกเว้น default "_") จาก project confs → เป็น -d flags
DOMAINS=$(grep -rhoE 'server_name[^;]+;' nginx/projects/*.conf 2>/dev/null \
  | sed -E 's/server_name//; s/;//' \
  | tr ' ' '\n' \
  | grep -vE '^[[:space:]]*$|^_$' \
  | sort -u)

if [ -z "${DOMAINS}" ]; then
  echo "ไม่พบโดเมนใน nginx/projects/*.conf" >&2
  exit 1
fi

ARGS=""
for d in ${DOMAINS}; do ARGS="${ARGS} -d ${d}"; done

echo "ออก SAN cert '${CERT_NAME}' สำหรับโดเมน:"
echo "${DOMAINS}" | sed 's/^/  - /'
echo ""

# หมายเหตุ: โดเมนต้องชี้ DNS มาที่ IP ของ edge + port 80 เข้าถึงได้ (ACME http-01)
# --entrypoint certbot: จำเป็น! เพราะ certbot service ตั้ง entrypoint เป็น renew loop
#   ถ้าไม่ override คำสั่ง certonly จะโดน loop กลืน → ค้าง ไม่ออก cert
docker compose run --rm --entrypoint certbot certbot certonly \
  --webroot -w /var/www/certbot \
  --cert-name "${CERT_NAME}" \
  ${ARGS} \
  --email "${EMAIL}" --agree-tos --no-eff-email

echo ""
echo "เสร็จ — nginx จะ reload อัตโนมัติ (20-reload-*.sh เฝ้าไฟล์ cert อยู่)"
