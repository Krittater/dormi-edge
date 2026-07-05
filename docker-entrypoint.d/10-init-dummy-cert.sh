#!/bin/sh
set -eu

# ---------------------------------------------------------------
# สร้าง cert ปลอม (self-signed) ให้ nginx start ได้ก่อน
# ที่ certbot จะออก cert จริง — แก้ปัญหา "ไก่กับไข่"
# (nginx เปิด 443 ไม่ได้ถ้าไม่มี cert / certbot ออก cert ไม่ได้ถ้า nginx ไม่ start)
#
# ลำดับ:
#   1. container start → script นี้รัน (10-*)
#   2. ถ้ามี cert อยู่แล้ว → ข้าม
#   3. ถ้าไม่มี → สร้าง dummy → nginx start → certbot ทำ ACME challenge ได้
#      → cert จริงมาแทน → 20-*.sh (inotify) reload nginx อัตโนมัติ
# ---------------------------------------------------------------

CERT_NAME="edge-dormi"
LIVE_DIR="/etc/letsencrypt/live/${CERT_NAME}"
FULLCHAIN="${LIVE_DIR}/fullchain.pem"
PRIVKEY="${LIVE_DIR}/privkey.pem"

if [ -f "${FULLCHAIN}" ] && [ -f "${PRIVKEY}" ]; then
  echo "[entrypoint] Certificate already exists at ${LIVE_DIR}; skipping dummy generation" >&2
  exit 0
fi

echo "[entrypoint] No certificate found — generating dummy self-signed cert for initial startup" >&2

mkdir -p "${LIVE_DIR}"

openssl req -x509 -nodes -newkey rsa:2048 \
  -days 1 \
  -keyout "${PRIVKEY}" \
  -out "${FULLCHAIN}" \
  -subj "/CN=dummy.edge.local" \
  2>/dev/null

echo "[entrypoint] Dummy cert created at ${LIVE_DIR} (replace with real cert via certbot)" >&2
