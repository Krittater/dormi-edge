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
API_HOST="dormi-api.dormi-linkandrent.com"

# ยืนยันว่า revert แล้ว "ใช้งานได้จริง" ไม่ใช่แค่ compose up คืน exit 0
# (snapshot ตรวจ health ก่อน deploy — revert ก็ต้องตรวจหลังคืนค่าเหมือนกัน)
health_poll() {  # $1=host $2=expected_short
  local i body ver
  for i in $(seq 1 20); do
    body="$(curl -fsS --max-time 5 --resolve "$1:443:127.0.0.1" "https://$1/version" 2>/dev/null || true)"
    ver="$(printf '%s' "$body" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [ "$ver" = "$2" ] && return 0
    sleep 3
  done
  return 1
}

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

# ★ คืน git clone ให้ตรงกับ image ที่ revert กลับ (ปิด H2)
#   ไม่งั้น clone ค้างที่ commit ใหม่ → full-update รอบถัดไป diff มองไม่เห็น migration
#   → ข้าม backup/marker ทั้งที่ DB ถูก restore กลับ schema เก่าไปแล้ว
if [ -n "${BE_COMMIT:-}" ] && [ -d "$BE_DIR/.git" ]; then
  if git -C "$BE_DIR" reset --hard "$BE_COMMIT" >/dev/null 2>&1; then
    echo "🔁 reset clone → ${BE_COMMIT:0:7} (ให้ตรงกับ image ที่คืน)"
  else
    echo "⚠️ reset clone ไป $BE_COMMIT ไม่สำเร็จ (ไม่บล็อก revert — แต่รอบหน้า detection พึ่ง DB-check)"
  fi
fi

# /version สะท้อน commit เก่าที่คืนกลับ
export APP_VERSION="${BE_COMMIT:0:7}"

echo "↩️ recreate ($SERVICES) จาก image :prev — commit ${BE_COMMIT:0:7}"
cd "$BE_DIR/$COMPOSE_DIR"
# --no-build = ใช้ image ที่ retag ไว้ ไม่ build ใหม่ (postgres ไม่ถูกแตะ)
if ! $COMPOSE up -d --no-build --force-recreate $SERVICES; then
  echo "❌ recreate จาก image :prev ล้มเหลว"
  echo " STATUS: FAILED"
  exit 1
fi

# ★ ยืนยันด้วย /version ว่าคืนกลับสำเร็จจริง (ไม่ใช่แค่ container ขึ้น)
if health_poll "$API_HOST" "${BE_COMMIT:0:7}"; then
  echo "✅ revert backend สำเร็จ → :prev (${BE_COMMIT:0:7}) + health OK"
  echo " STATUS: SUCCESS"
  exit 0
fi

echo "❌ recreate ผ่าน แต่ /version ไม่กลับมาเป็น ${BE_COMMIT:0:7} ภายใน 60s"
echo "   ตรวจ: docker logs --tail=50 docker-dormi-api-1"
echo "   และ : curl -s https://$API_HOST/version"
echo " STATUS: FAILED (revert ไม่ยืนยัน)"
exit 1
