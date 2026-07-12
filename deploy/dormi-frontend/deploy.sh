#!/bin/bash
# Deploy dormi-fe-2 — อ้างอิง README ของ repo dormi-fronend (GitHub: dormi-fe-2)
# รันบน server: cd /root/dormi-edge/deploy/dormi-frontend && bash deploy.sh
#
# ก่อนรันครั้งแรก (ทำมือครั้งเดียว — ดู README):
#   - backend + edge deploy แล้ว
#   - clone https://github.com/Krittater/dormi-fe-2.git → /root/dormi-fe-2
#   - scp .env.production ขึ้น server (NEXT_PUBLIC_API_URL ถูก bake ตอน build)

set -e

APP_NAME="dormi-fe-2"
APP_DIR="/root/$APP_NAME"
GIT_BRANCH="main"

echo "========================"
echo " Deploy: $APP_NAME"
echo "========================"

if [ ! -d "$APP_DIR" ]; then
    echo "❌ ไม่พบ $APP_DIR — clone ก่อน: git clone https://github.com/Krittater/dormi-fe-2.git"
    exit 1
fi

if [ ! -f "$APP_DIR/.env.production" ]; then
    echo "❌ ไม่พบ $APP_DIR/.env.production"
    echo "   scp ไฟล์จากเครื่องเราก่อน (ดู README § ส่งไฟล์ env ขึ้น server)"
    echo "   ตัวอย่าง: NEXT_PUBLIC_API_URL=https://dormi-api.dormi-linkandrent.com"
    exit 1
fi

# frontend ต่อ dormi_network (README § build + รัน)
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
# 2. build + restart (README § build + รัน)
# =========================
echo "Build and restart containers..."

# ส่ง commit ที่ deploy เข้า container → โผล่ที่ GET /version (compose อ่าน ${APP_VERSION}, runtime env)
export APP_VERSION="$(git rev-parse --short HEAD)"
echo "🔖 APP_VERSION=$APP_VERSION"

docker compose up -d --build

docker image prune -f

# =========================
# 3. check status
# =========================
echo "Checking compose status..."

FAILED=$(docker compose ps --services --filter "status=exited")

if [ ! -z "$FAILED" ]; then
    echo "❌ DEPLOY FAILED"

    echo "❌ Failed services:"
    echo "$FAILED"

    echo "🔁 Rolling back..."

    echo "↩️ Rollback FROM: $NEW_COMMIT"
    echo "↩️ Rollback TO:   $OLD_COMMIT"

    git reset --hard "$OLD_COMMIT"

    # /version สะท้อน commit เก่าที่ rollback กลับมา
    export APP_VERSION="$(git rev-parse --short HEAD)"

    docker compose up -d --build --force-recreate

    echo "========================"
    echo " ROLLBACK DONE"
    echo " Current commit: $OLD_COMMIT"
    echo "========================"

    exit 1
fi

# =========================
# 4. ตรวจหลัง deploy (README § ตรวจว่าขึ้นจริง)
# =========================
echo "Post-deploy checks..."

docker ps --format "table {{.Names}}\t{{.Status}}" | grep dormi-web || true

WEB_CONTAINER=$(docker ps --format '{{.Names}}' | grep 'dormi-web' | head -1)
if [ -n "$WEB_CONTAINER" ]; then
    echo "📋 Logs ($WEB_CONTAINER):"
    docker logs "$WEB_CONTAINER" 2>&1 | tail -3
else
    echo "⚠️ ไม่พบ container dormi-web"
fi

echo "========================"
echo " DEPLOY SUCCESS"
echo " OLD COMMIT : $OLD_COMMIT"
echo " NEW COMMIT : $NEW_COMMIT"
echo " STATUS     : OK"
echo " ทดสอบ     : curl https://dormi-linkandrent.com/login"
echo "========================"
