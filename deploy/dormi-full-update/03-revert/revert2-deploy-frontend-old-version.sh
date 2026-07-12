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
if docker compose up -d --no-build --force-recreate dormi-web; then
  echo "✅ revert frontend สำเร็จ → :prev (ไม่ได้ build ใหม่)"
  echo " STATUS: SUCCESS"
  exit 0
else
  echo "❌ recreate จาก image :prev ล้มเหลว"
  echo " STATUS: FAILED"
  exit 1
fi
