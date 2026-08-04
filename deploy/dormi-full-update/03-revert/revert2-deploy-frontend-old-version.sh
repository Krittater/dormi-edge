#!/bin/bash
# 03-revert/revert2-deploy-frontend-old-version.sh
# คืน frontend เป็น image เก่า (:prev ที่ snapshot tag ไว้) — ไม่ต้อง build
# ------------------------------------------------------------------
# วิธี: retag image :prev → ชื่อที่ compose ใช้ แล้ว recreate โดยไม่ build
set -uo pipefail

SNAP_ENV="/root/dormi-releases/snapshots/latest/snapshot.env"
FE_DIR="/root/dormi-fe-2"
# ชื่อ image ที่ compose ใช้ (project=dormi-fe-2)
COMPOSE_WEB_IMG="dormi-fe-2-dormi-web:latest"
WEB_HOST="dormi-linkandrent.com"
# frontend อยู่ใต้ basePath /app (หน้าแรกของโดเมนถูกยกให้เว็บ market)
WEB_VERSION_PATH="/app/version"

# ยืนยันว่า revert แล้ว "ใช้งานได้จริง" ไม่ใช่แค่ compose up คืน exit 0
# (snapshot ตรวจ health ก่อน deploy — revert ก็ต้องตรวจหลังคืนค่าเหมือนกัน)
health_poll() {  # $1=host $2=expected_short
  local i body ver
  for i in $(seq 1 20); do
    body="$(curl -fsS --max-time 5 --resolve "$1:443:127.0.0.1" "https://$1${WEB_VERSION_PATH}" 2>/dev/null || true)"
    ver="$(printf '%s' "$body" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [ "$ver" = "$2" ] && return 0
    sleep 3
  done
  return 1
}

echo "========================"
echo " Revert 2 — frontend → image เก่า (:prev)"
echo "========================"

[ -f "$SNAP_ENV" ] || { echo "❌ ไม่พบ snapshot: $SNAP_ENV"; echo " STATUS: FAILED"; exit 1; }
set -a; . "$SNAP_ENV"; set +a

if ! docker image inspect "$FE_ROLLBACK_TAG" >/dev/null 2>&1; then
  echo "❌ ไม่พบ image $FE_ROLLBACK_TAG (ถูก prune?) — revert แบบไม่ build ทำไม่ได้"
  echo " STATUS: FAILED"
  exit 1
fi

# retag :prev → ชื่อ compose
docker tag "$FE_ROLLBACK_TAG" "$COMPOSE_WEB_IMG"

# คืน git clone ให้ตรงกับ image ที่ revert กลับ (สมมาตรกับ revert1 — กัน clone/image desync)
if [ -n "${FE_COMMIT:-}" ] && [ -d "$FE_DIR/.git" ]; then
  git -C "$FE_DIR" reset --hard "$FE_COMMIT" >/dev/null 2>&1 \
    && echo "🔁 reset clone → ${FE_COMMIT:0:7} (ให้ตรงกับ image ที่คืน)" \
    || echo "⚠️ reset clone ไม่สำเร็จ (ไม่บล็อก revert)"
fi

# /version สะท้อน commit เก่าที่คืนกลับ
export APP_VERSION="${FE_COMMIT:0:7}"

echo "↩️ recreate (dormi-web) จาก image :prev — commit ${FE_COMMIT:0:7}"
cd "$FE_DIR"
if ! docker compose up -d --no-build --force-recreate dormi-web; then
  echo "❌ recreate จาก image :prev ล้มเหลว"
  echo " STATUS: FAILED"
  exit 1
fi

# ★ ยืนยันด้วย /version ว่าคืนกลับสำเร็จจริง (ไม่ใช่แค่ container ขึ้น)
if health_poll "$WEB_HOST" "${FE_COMMIT:0:7}"; then
  echo "✅ revert frontend สำเร็จ → :prev (${FE_COMMIT:0:7}) + health OK"
  echo " STATUS: SUCCESS"
  exit 0
fi

echo "❌ recreate ผ่าน แต่ /version ไม่กลับมาเป็น ${FE_COMMIT:0:7} ภายใน 60s"
echo "   ตรวจ: docker compose -f $FE_DIR/docker-compose.yml logs --tail=50 dormi-web"
echo "   และ : curl -s https://$WEB_HOST$WEB_VERSION_PATH"
echo " STATUS: FAILED (revert ไม่ยืนยัน)"
exit 1
