#!/bin/bash
# 02-deploy/step2-backend-deploy.sh — deploy backend (ไม่ revert เอง — workflow เรียก revert)
# ------------------------------------------------------------------
# deploy → health check ผ่าน /version → พัง = exit 1
#   job 'revert-backend' (image :prev) จะ revert ให้ — DB ไม่ถอยอัตโนมัติ (revert-db.yml = มือ)
# รันบน server (ผ่าน job 'backend'):  bash step2-backend-deploy.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

BE_DIR="/root/dormi-backend-2"
BE_BRANCH="master"
COMPOSE_DIR="docker"
COMPOSE="docker compose --env-file .env.production -f docker-compose.yml -f docker-compose.prod.yml"
API_HOST="dormi-api.dormi-linkandrent.com"

# poll /version จนกว่าจะเห็น version = target (พิสูจน์ code ใหม่ขึ้นจริง) หรือ timeout ~60s
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
echo " Step 2 — Backend deploy"
echo "========================"

[ -d "$BE_DIR/.git" ] || { echo "❌ ไม่พบ $BE_DIR"; exit 1; }

# ensure clone ที่ target (step1 อาจ pull แล้ว; ถ้า step1 ข้ามก็ pull เอง)
git -C "$BE_DIR" fetch -q origin "$BE_BRANCH" && git -C "$BE_DIR" reset --hard "origin/$BE_BRANCH"
TARGET_SHORT="$(git -C "$BE_DIR" rev-parse --short HEAD)"
echo "🎯 target commit: $TARGET_SHORT"

# --- deploy ---
export APP_VERSION="$TARGET_SHORT"   # → /version คืน commit นี้
cd "$BE_DIR/$COMPOSE_DIR"

DEPLOY_OK=true
if ! $COMPOSE up -d --build; then
  echo "❌ compose build/up ล้มเหลว"
  DEPLOY_OK=false
fi
docker image prune -f >/dev/null 2>&1 || true   # old image ยังรอด (มี tag :prev)

# --- health check ---
if [ "$DEPLOY_OK" = true ] && health_poll "$API_HOST" "$TARGET_SHORT"; then
  echo "========================"
  echo " ✅ BACKEND DEPLOY สำเร็จ + health OK (version=$TARGET_SHORT)"
  echo " STATUS: SUCCESS"
  echo "========================"
  exit 0
fi

# --- พัง → exit 1 (ไม่ revert เอง) ---
# workflow: job 'backend' fail → job 'revert-backend' (image :prev) เท่านั้น
# ★ DB ไม่ถูกถอยอัตโนมัติ (กันข้อมูลผู้ใช้ที่เขียนระหว่าง deploy หาย)
echo "========================"
echo " ❌ BACKEND พัง (build/health) — exit 1"
echo "    → job 'revert-backend' จะคืน image :prev ให้ (DB ไม่ถูกถอยอัตโนมัติ)"
if [ -f /root/dormi-releases/snapshots/latest/MIGRATION_RAN ]; then
  echo "    ⚠️ รอบนี้มี migration — schema ล้ำหน้า code เก่า:"
  echo "       • additive (เพิ่ม column/table) → ปล่อยได้ code เก่ารันต่อได้"
  echo "       • destructive → ถอย DB เอง: gh workflow run revert-db.yml"
fi
echo " STATUS: BACKEND FAILED"
echo "========================"
exit 1
