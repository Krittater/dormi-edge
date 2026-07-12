#!/bin/bash
# 03-revert/revert1-deploy-backend-old-version.sh
# คืน backend เป็น image เก่า (:prev ที่ snapshot tag ไว้) — ไม่ต้อง build (ไม่พังซ้ำ)
# ------------------------------------------------------------------
# วิธี: retag image :prev → ชื่อที่ compose ใช้ แล้ว recreate container โดยไม่ build
# อ่านจุดกลับจาก snapshot.env (ตัวชี้ latest)
set -uo pipefail

SNAP_ENV="/root/dormi-releases/snapshots/latest/snapshot.env"
BE_DIR="/root/dormi-backend-2"
COMPOSE_DIR="docker"
COMPOSE="docker compose --env-file .env.production -f docker-compose.yml -f docker-compose.prod.yml"
# ชื่อ image ที่ compose ใช้ (project=docker → <project>-<service>)
COMPOSE_API_IMG="docker-dormi-api:latest"
COMPOSE_SCHED_IMG="docker-dormi-scheduler:latest"

echo "========================"
echo " Revert 1 — backend → image เก่า (:prev)"
echo "========================"

[ -f "$SNAP_ENV" ] || { echo "❌ ไม่พบ snapshot: $SNAP_ENV"; echo " STATUS: FAILED"; exit 1; }
set -a; . "$SNAP_ENV"; set +a

# ต้องมี image :prev ของ api จริง (ไม่งั้น revert แบบไม่ build ทำไม่ได้)
if ! docker image inspect "$BE_API_ROLLBACK_TAG" >/dev/null 2>&1; then
  echo "❌ ไม่พบ image $BE_API_ROLLBACK_TAG (ถูก prune?) — revert แบบไม่ build ทำไม่ได้"
  echo " STATUS: FAILED"
  exit 1
fi

# retag :prev → ชื่อ compose (api บังคับ, scheduler best-effort)
docker tag "$BE_API_ROLLBACK_TAG" "$COMPOSE_API_IMG"
SERVICES="dormi-api"
if docker image inspect "$BE_SCHED_ROLLBACK_TAG" >/dev/null 2>&1; then
  docker tag "$BE_SCHED_ROLLBACK_TAG" "$COMPOSE_SCHED_IMG"
  SERVICES="$SERVICES dormi-scheduler"
else
  echo "⚠️ ไม่มี scheduler image :prev — recreate เฉพาะ api (scheduler คงเวอร์ชันปัจจุบัน)"
fi

# /version สะท้อน commit เก่าที่คืนกลับ
export APP_VERSION="${BE_COMMIT:0:7}"

echo "↩️ recreate ($SERVICES) จาก image :prev — commit ${BE_COMMIT:0:7}"
cd "$BE_DIR/$COMPOSE_DIR"
# --no-build = ใช้ image ที่ retag ไว้ ไม่ build ใหม่ (postgres ไม่ถูกแตะ)
if $COMPOSE up -d --no-build --force-recreate $SERVICES; then
  echo "✅ revert backend สำเร็จ → :prev (ไม่ได้ build ใหม่)"
  echo " STATUS: SUCCESS"
  exit 0
else
  echo "❌ recreate จาก image :prev ล้มเหลว"
  echo " STATUS: FAILED"
  exit 1
fi
