#!/bin/sh
set -eu

# ============================================================
# ออก/ต่ออายุ SAN cert ของ edge ทีละ "ชื่อ cert"
#
#   sh scripts/issue-cert.sh                       → cert edge-dormi (ค่าเริ่มต้น)
#   sh scripts/issue-cert.sh edge-landing          → cert edge-landing (apex + www)
#   sh scripts/issue-cert.sh <ชื่อ> --print-domains → แค่พิมพ์รายชื่อโดเมน ไม่เรียก certbot
#
# โดเมนของแต่ละ cert = server_name ของ "ไฟล์ conf ที่อ้าง live/<CERT_NAME>/"
# (บรรทัด ssl_certificate ที่ไม่ใช่คอมเมนต์) เท่านั้น
#   → เพิ่ม project ใหม่ที่ใช้ cert เดิม = แค่เพิ่มไฟล์ conf แล้วรัน script นี้
#   → แยก cert ได้ (เช่น landing) โดยโดเมนที่ DNS ยังไม่ชี้มา edge จะไม่ไปทำ cert หลัก fail
#
# ต้องรันจาก root ของ dormi-edge (ที่มี docker-compose.yml)
# ============================================================

CERT_NAME="edge-dormi"
PRINT_ONLY=0
for a in "$@"; do
  case "$a" in
    --print-domains) PRINT_ONLY=1 ;;
    -*) echo "ไม่รู้จัก option: $a" >&2; exit 2 ;;
    *)  CERT_NAME="$a" ;;
  esac
done
EMAIL="${CERTBOT_EMAIL:-admin@dormi-linkandrent.com}"

# ไฟล์ conf ที่ใช้ cert นี้ (ตัดคอมเมนต์ก่อน เพื่อไม่ให้ข้อความอธิบายไปปนกับ directive จริง)
CONF_FILES=""
for f in nginx/projects/*.conf; do
  [ -f "$f" ] || continue
  if sed 's/#.*//' "$f" | grep -qE "ssl_certificate(_key)?[[:space:]]+[^;]*live/${CERT_NAME}/"; then
    CONF_FILES="${CONF_FILES} ${f}"
  fi
done

# ดึงทุก server_name (ยกเว้น default "_") จากไฟล์เหล่านั้น → เป็น -d flags
DOMAINS=""
if [ -n "${CONF_FILES}" ]; then
  # shellcheck disable=SC2086
  DOMAINS=$(sed 's/#.*//' ${CONF_FILES} \
    | grep -oE 'server_name[^;]+;' \
    | sed -E 's/server_name//; s/;//' \
    | tr ' ' '\n' \
    | grep -vE '^[[:space:]]*$|^_$' \
    | sort -u)
fi

if [ -z "${DOMAINS}" ]; then
  echo "ไม่พบโดเมนของ cert '${CERT_NAME}' ใน nginx/projects/*.conf (ต้องมี conf ที่อ้าง live/${CERT_NAME}/)" >&2
  exit 1
fi

if [ "${PRINT_ONLY}" = "1" ]; then
  echo "${DOMAINS}"
  exit 0
fi

ARGS=""
for d in ${DOMAINS}; do ARGS="${ARGS} -d ${d}"; done

echo "ออก SAN cert '${CERT_NAME}' สำหรับโดเมน:"
echo "${DOMAINS}" | sed 's/^/  - /'
echo ""

# ย้าย dummy cert ที่ 10-init-dummy-cert.sh สร้างตอน boot ออกไปพักก่อน
# (certbot ปฏิเสธถ้าเจอ live dir ที่ไม่มี renewal config = ไม่ใช่ของมันเอง
#  แล้วจะเลี่ยงไปสร้างชื่อ <name>-0001 ทำให้ path ไม่ตรง nginx)
# ใช้ -s (ไฟล์ไม่ว่าง) → renewal conf เปล่าจากรอบ fail ไม่นับว่าเป็น cert จริง
# ทำเฉพาะ CERT_NAME ที่ส่งเข้ามา — ไม่แตะ cert ใบอื่น
# ★ พักไว้ ไม่ลบทิ้ง: ถ้า certbot ล้ม ต้องคืน dummy ทันที ไม่งั้น conf ที่อ้าง live/<CERT_NAME>/
#   จะชี้ไฟล์ที่ไม่มี → edge restart เมื่อไหร่ nginx ไม่ขึ้นทั้งตัว (ทุกโดเมนล่ม)
CONF_DIR="data/certbot/conf"
PARKED="${CONF_DIR}/.parked-${CERT_NAME}"
PARKED_DUMMY=0
if [ ! -s "${CONF_DIR}/renewal/${CERT_NAME}.conf" ] && [ -d "${CONF_DIR}/live/${CERT_NAME}" ]; then
  echo "พบ dummy/junk cert เดิม — ย้ายไปพักที่ ${PARKED} ก่อนออก cert จริง"
  rm -rf "${PARKED}"
  mkdir -p "${PARKED}"
  mv "${CONF_DIR}/live/${CERT_NAME}" "${PARKED}/live"
  if [ -d "${CONF_DIR}/archive/${CERT_NAME}" ]; then mv "${CONF_DIR}/archive/${CERT_NAME}" "${PARKED}/archive"; fi
  rm -f "${CONF_DIR}/renewal/${CERT_NAME}.conf"
  PARKED_DUMMY=1
fi

restore_dummy() {
  [ "${PARKED_DUMMY}" = "1" ] || return 0
  echo "คืน dummy cert '${CERT_NAME}' กลับที่เดิม (กัน nginx ไม่ขึ้นตอน restart)" >&2
  rm -rf "${CONF_DIR}/live/${CERT_NAME}" "${CONF_DIR}/archive/${CERT_NAME}" "${CONF_DIR}/renewal/${CERT_NAME}.conf"
  mv "${PARKED}/live" "${CONF_DIR}/live/${CERT_NAME}"
  if [ -d "${PARKED}/archive" ]; then mv "${PARKED}/archive" "${CONF_DIR}/archive/${CERT_NAME}"; fi
  rm -rf "${PARKED}"
}

# หมายเหตุ: โดเมนต้องชี้ DNS มาที่ IP ของ edge + port 80 เข้าถึงได้ (ACME http-01)
# --entrypoint certbot: จำเป็น! เพราะ certbot service ตั้ง entrypoint เป็น renew loop
#   ถ้าไม่ override คำสั่ง certonly จะโดน loop กลืน → ค้าง ไม่ออก cert
# --non-interactive + --expand: จำเป็นเมื่อ "รายชื่อโดเมนในใบเปลี่ยน"
#   (เพิ่ม/ลดโดเมน เช่นตอนย้าย dormi-linkandrent.com ออกแล้วใส่ app. เข้ามา)
#   ถ้าไม่ใส่ certbot จะหยุดถามยืนยัน (E)xpand/(C)ancel แล้วค้างรอ input
#   → รันผ่าน ssh/CI จะแขวนจนหมดเวลาโดยไม่บอกสาเหตุ
# shellcheck disable=SC2086
if ! docker compose run --rm --entrypoint certbot certbot certonly \
  --webroot -w /var/www/certbot \
  --cert-name "${CERT_NAME}" \
  ${ARGS} \
  --non-interactive --expand \
  --email "${EMAIL}" --agree-tos --no-eff-email; then
  restore_dummy
  echo "ออก cert '${CERT_NAME}' ไม่สำเร็จ — ตรวจ DNS / port 80 ก่อนลองใหม่ (Let's Encrypt จำกัดที่ล้ม 5 ครั้ง/ชม.)" >&2
  exit 1
fi
rm -rf "${PARKED}"

echo ""
echo "เสร็จ — nginx จะ reload อัตโนมัติ (20-reload-*.sh เฝ้าไฟล์ cert อยู่)"
