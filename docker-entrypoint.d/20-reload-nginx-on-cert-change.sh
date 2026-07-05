#!/bin/sh
set -eu

# ---------------------------------------------------------------
# เฝ้าดูไฟล์ cert ใน /etc/letsencrypt แล้ว reload nginx อัตโนมัติ
# เมื่อ certbot (container dormi-certbot) ต่ออายุ cert ลง shared volume
# reload เฉพาะเมื่อ nginx -t ผ่าน (production-safe)
# ---------------------------------------------------------------

if ! command -v inotifywait >/dev/null 2>&1; then
  echo "[entrypoint] inotifywait not found; cert auto-reload disabled" >&2
  exit 0
fi

CERT_DIR="/etc/letsencrypt"
mkdir -p "${CERT_DIR}"

# รัน watcher เป็น background เพื่อให้ nginx start ตามปกติ
(
  echo "[entrypoint] Watching cert changes in ${CERT_DIR} (will nginx -s reload)" >&2

  while true; do
    inotifywait -q -r -e close_write,move,create,delete "${CERT_DIR}" >/dev/null 2>&1 || true

    # หน่วงเล็กน้อยให้ไฟล์จาก renewal batch เขียนเสร็จก่อน
    sleep 5

    if nginx -t 2>/dev/null; then
      echo "[entrypoint] Cert updated; reloading nginx" >&2
      nginx -s reload || true
    else
      echo "[entrypoint] Cert changed but nginx -t failed; skipping reload" >&2
    fi
  done
) &
