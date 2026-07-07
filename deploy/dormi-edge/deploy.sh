#!/bin/bash
# Deploy dormi-edge — อ้างอิง README ของ repo dormi-edge
# รันบน server: cd /root/dormi-edge/deploy/dormi-edge && bash deploy.sh
#
# ก่อนรันครั้งแรก (ทำมือครั้งเดียว — ดู README):
#   - backend deploy แล้ว + DNS ชี้มา server + firewall เปิด 80/443
#   - clone https://github.com/Krittater/dormi-edge.git → /root/dormi-edge
#   - echo "CERTBOT_EMAIL=..." > .env
#   - ออก cert จริง: set -a && . ./.env && set +a && sh scripts/issue-cert.sh

set -e

APP_NAME="dormi-edge"
APP_DIR="/root/$APP_NAME"
GIT_BRANCH="main"

echo "========================"
echo " Deploy: $APP_NAME"
echo "========================"

if [ ! -d "$APP_DIR" ]; then
    echo "❌ ไม่พบ $APP_DIR — clone ก่อน: git clone https://github.com/Krittater/dormi-edge.git"
    exit 1
fi

cd "$APP_DIR"

# =========================
# 🧠 0. เก็บ commit ปัจจุบัน
# =========================
OLD_COMMIT=$(git rev-parse HEAD)
echo "📌 OLD COMMIT (ก่อน deploy): $OLD_COMMIT"

# =========================
# 1. pull latest (README § เมื่อแก้ config)
# =========================
echo "Pull latest code..."

git fetch origin "$GIT_BRANCH"
git checkout "$GIT_BRANCH"
git reset --hard "origin/$GIT_BRANCH"

NEW_COMMIT=$(git rev-parse HEAD)
echo "📌 NEW COMMIT (หลัง pull): $NEW_COMMIT"

# =========================
# 2. เลือกวิธี deploy ตาม README
#    - แก้ nginx conf เท่านั้น → reload (ไม่ rebuild)
#    - แก้ Dockerfile / entrypoint / compose → up -d --build
#    - ยังไม่มี container → up -d --build (ครั้งแรก)
# =========================
CHANGED=$(git diff --name-only "$OLD_COMMIT" "$NEW_COMMIT" 2>/dev/null || true)
NEEDS_REBUILD=false

if ! docker ps --format '{{.Names}}' | grep -q '^dormi-edge$'; then
    echo "📦 ยังไม่มี dormi-edge container — จะ build ครั้งแรก"
    NEEDS_REBUILD=true
elif echo "$CHANGED" | grep -qE '^(Dockerfile|docker-compose\.yml|docker-entrypoint\.d/)'; then
    echo "📦 ตรวจพบการเปลี่ยน Dockerfile/compose/entrypoint — จะ rebuild"
    NEEDS_REBUILD=true
else
    echo "📄 เปลี่ยนเฉพาะ config (หรือไม่มี diff) — reload nginx ตาม README"
fi

rollback() {
    echo "🔁 Rolling back..."
    echo "↩️ Rollback FROM: $NEW_COMMIT"
    echo "↩️ Rollback TO:   $OLD_COMMIT"

    git reset --hard "$OLD_COMMIT"

    if [ "$NEEDS_REBUILD" = true ]; then
        docker compose up -d --build --force-recreate
    else
        docker exec dormi-edge nginx -t
        docker exec dormi-edge nginx -s reload
    fi

    echo "========================"
    echo " ROLLBACK DONE"
    echo " Current commit: $OLD_COMMIT"
    echo "========================"
}

if [ "$NEEDS_REBUILD" = true ]; then
    # README § สร้าง network + start edge (ครั้งแรก / แก้ image)
    docker network create dormi_network 2>/dev/null || true

    echo "Build and restart containers..."
    docker compose up -d --build
    docker image prune -f

    echo "Checking compose status..."
    FAILED=$(docker compose ps --services --filter "status=exited")

    if [ ! -z "$FAILED" ]; then
        echo "❌ DEPLOY FAILED"
        echo "❌ Failed services:"
        echo "$FAILED"
        rollback
        exit 1
    fi
else
    # README § เมื่อแก้ config รอบถัดไป: nginx -t && reload
    echo "Reload nginx config..."
    if ! docker exec dormi-edge nginx -t; then
        echo "❌ nginx -t FAILED"
        rollback
        exit 1
    fi
    docker exec dormi-edge nginx -s reload
fi

# =========================
# 3. ตรวจหลัง deploy (README § ตรวจ)
# =========================
echo "Post-deploy checks..."
docker exec dormi-edge nginx -t

echo "========================"
echo " DEPLOY SUCCESS"
echo " OLD COMMIT : $OLD_COMMIT"
echo " NEW COMMIT : $NEW_COMMIT"
echo " MODE       : $([ "$NEEDS_REBUILD" = true ] && echo 'rebuild' || echo 'reload')"
echo " STATUS     : OK"
echo " ทดสอบ     : curl https://dormi-api.dormi-linkandrent.com/whoami"
echo "========================"
