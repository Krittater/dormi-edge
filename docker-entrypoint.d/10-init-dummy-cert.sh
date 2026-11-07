#!/bin/sh
set -eu

# ---------------------------------------------------------------
# สร้าง cert ปลอม (self-signed) ให้ nginx start ได้ก่อน
# ที่ certbot จะออก cert จริง — แก้ปัญหา "ไก่กับไข่"
# (nginx เปิด 443 ไม่ได้ถ้าไม่มี cert / certbot ออก cert ไม่ได้ถ้า nginx ไม่ start)
#
# ลำดับ:
#   1. container start → script นี้รัน (10-*)
#   2. หา "ทุกชื่อ cert" ที่ conf ใน /etc/nginx/projects/*.conf อ้างถึง
#      (จากบรรทัด ssl_certificate .../live/<ชื่อ>/... ที่ไม่ใช่คอมเมนต์)
#      เช่น edge-dormi, edge-landing
#   3. ชื่อไหนมี cert อยู่แล้ว → ข้าม · ชื่อไหนยังไม่มี → สร้าง dummy
#      → nginx start → certbot ทำ ACME challenge ได้
#      → cert จริงมาแทน → 20-*.sh (inotify) reload nginx อัตโนมัติ
# ---------------------------------------------------------------

PROJECTS_DIR="${PROJECTS_DIR:-/etc/nginx/projects}"
LE_DIR="${LE_DIR:-/etc/letsencrypt}"

CERT_NAMES=$(sed 's/#.*//' "${PROJECTS_DIR}"/*.conf 2>/dev/null \
  | grep -oE 'live/[^/[:space:];]+/' \
  | cut -d/ -f2 \
  | sort -u)

# ไม่เจอ conf เลย (เช่น mount พลาด) → ถอยกลับไปใช้ชื่อเดิม เพื่อพฤติกรรมเดิมไม่เปลี่ยน
if [ -z "${CERT_NAMES}" ]; then
  CERT_NAMES="edge-dormi"
fi

for CERT_NAME in ${CERT_NAMES}; do
  LIVE_DIR="${LE_DIR}/live/${CERT_NAME}"
  FULLCHAIN="${LIVE_DIR}/fullchain.pem"
  PRIVKEY="${LIVE_DIR}/privkey.pem"

  if [ -f "${FULLCHAIN}" ] && [ -f "${PRIVKEY}" ]; then
    echo "[entrypoint] Certificate '${CERT_NAME}' already exists at ${LIVE_DIR}; skipping dummy generation" >&2
    continue
  fi

  echo "[entrypoint] No certificate '${CERT_NAME}' — generating dummy self-signed cert for initial startup" >&2

  mkdir -p "${LIVE_DIR}"

  openssl req -x509 -nodes -newkey rsa:2048 \
    -days 1 \
    -keyout "${PRIVKEY}" \
    -out "${FULLCHAIN}" \
    -subj "/CN=dummy.edge.local" \
    2>/dev/null

  echo "[entrypoint] Dummy cert '${CERT_NAME}' created at ${LIVE_DIR} (replace with real cert via certbot)" >&2
done
