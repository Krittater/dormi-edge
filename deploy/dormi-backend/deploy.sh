#!/bin/bash
# Deploy dormi-backend-2 — อ้างอิง README ของ repo dormi-backend-V2
# รันบน server: cd /root/dormi-edge/deploy/dormi-backend && bash deploy.sh
#
# ก่อนรันครั้งแรก (ทำมือครั้งเดียว — ดู README):
#   - clone https://github.com/Krittater/dormi-backend-2.git → /root/dormi-backend-2
#   - scp docker/.env และ docker/.env.production ขึ้น server
#   - docker network create dormi_network

set -e

APP_NAME="dormi-backend-2"
APP_DIR="/root/$APP_NAME"
GIT_BRANCH="master"
COMPOSE_DIR="docker"
ENV_FILE=".env.production"
COMPOSE="docker compose --env-file $ENV_FILE -f docker-compose.yml -f docker-compose.prod.yml"

echo "========================"
echo " Deploy: $APP_NAME"
echo "========================"

if [ ! -d "$APP_DIR" ]; then
    echo "❌ ไม่พบ $APP_DIR — clone ก่อน: git clone https://github.com/Krittater/dormi-backend-2.git"
    exit 1
fi

if [ ! -f "$APP_DIR/$COMPOSE_DIR/$ENV_FILE" ]; then
    echo "❌ ไม่พบ $APP_DIR/$COMPOSE_DIR/$ENV_FILE"
    echo "   scp ไฟล์ secret จากเครื่องเราก่อน (ดู README § ส่งไฟล์ secret ขึ้น server)"
    exit 1
fi

# network กลาง — ทุก service ของ dormi ใช้ร่วมกัน (README § สร้าง network กลาง)
docker network create dormi_network 2>/dev/null || true

cd "$APP_DIR"

# =========================
# 🧠 0. เก็บ commit ปัจจุบัน
# =========================
OLD_COMMIT=$(git rev-parse HEAD)
echo "📌 OLD COMMIT (ก่อน deploy): $OLD_COMMIT"

# =========================
# 1. pull latest (README § clone/pull)
# =========================
echo "Pull latest code..."

git fetch origin "$GIT_BRANCH"
git checkout "$GIT_BRANCH"
git reset --hard "origin/$GIT_BRANCH"

NEW_COMMIT=$(git rev-parse HEAD)
echo "📌 NEW COMMIT (หลัง pull): $NEW_COMMIT"

# =========================
# 2. build + restart (README § build + รันทั้ง stack)
# =========================
echo "Build and restart containers..."

cd "$APP_DIR/$COMPOSE_DIR"
$COMPOSE up -d --build

docker image prune -f

# =========================
# 3. check status
# =========================
echo "Checking compose status..."

FAILED=$($COMPOSE ps --services --filter "status=exited")

if [ ! -z "$FAILED" ]; then
    echo "❌ DEPLOY FAILED"

    echo "❌ Failed services:"
    echo "$FAILED"

    echo "🔁 Rolling back..."

    echo "↩️ Rollback FROM: $NEW_COMMIT"
    echo "↩️ Rollback TO:   $OLD_COMMIT"

    git -C "$APP_DIR" reset --hard "$OLD_COMMIT"

    $COMPOSE up -d --build --force-recreate

    echo "========================"
    echo " ROLLBACK DONE"
    echo " Current commit: $OLD_COMMIT"
    echo "========================"

    exit 1
fi

# =========================
# 4. ตรวจหลัง deploy (README § ตรวจว่าขึ้นครบ)
# =========================
echo "Post-deploy checks..."

docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "dormi_postgres|dormi-api|dormi-scheduler" || true

if ! docker ps --format '{{.Names}}' | grep -q '^dormi_postgres$'; then
    echo "⚠️ ไม่พบ dormi_postgres"
elif ! docker inspect dormi_postgres --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
    echo "⚠️ dormi_postgres ยังไม่ healthy — รอสักครู่แล้ว docker ps อีกครั้ง"
fi

echo "========================"
echo " DEPLOY SUCCESS"
echo " OLD COMMIT : $OLD_COMMIT"
echo " NEW COMMIT : $NEW_COMMIT"
echo " STATUS     : OK"
echo " ถัดไป     : deploy edge แล้วทดสอบ https://dormi-api.dormi-linkandrent.com"
echo "========================"
