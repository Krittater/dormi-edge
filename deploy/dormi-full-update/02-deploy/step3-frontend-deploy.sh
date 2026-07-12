#!/bin/bash
# 02-deploy/step3-frontend-deploy.sh — deploy frontend (ไม่ revert เอง — workflow เรียก revert)
# ------------------------------------------------------------------
# deploy → health check ผ่าน /version → พัง = exit 1
#   job 'revert-frontend' + 'revert-backend' (image :prev) จะ revert ให้
#   DB ไม่ถอยอัตโนมัติ (revert-db.yml = มือ — กันข้อมูลระหว่าง deploy หาย)
# รันบน server (ผ่าน job 'frontend'):  bash step3-frontend-deploy.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

FE_DIR="/root/dormi-fe-2"
FE_BRANCH="main"
WEB_HOST="dormi-linkandrent.com"

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
echo " Step 3 — Frontend deploy"
echo "========================"

[ -d "$FE_DIR/.git" ] || { echo "❌ ไม่พบ $FE_DIR"; exit 1; }

git -C "$FE_DIR" fetch -q origin "$FE_BRANCH" && git -C "$FE_DIR" reset --hard "origin/$FE_BRANCH"
TARGET_SHORT="$(git -C "$FE_DIR" rev-parse --short HEAD)"
echo "🎯 target commit: $TARGET_SHORT"

# --- deploy ---
export APP_VERSION="$TARGET_SHORT"
cd "$FE_DIR"

DEPLOY_OK=true
if ! docker compose up -d --build; then
  echo "❌ compose build/up ล้มเหลว"
  DEPLOY_OK=false
fi
docker image prune -f >/dev/null 2>&1 || true

# --- health check ---
if [ "$DEPLOY_OK" = true ] && health_poll "$WEB_HOST" "$TARGET_SHORT"; then
  echo "========================"
  echo " ✅ FRONTEND DEPLOY สำเร็จ + health OK (version=$TARGET_SHORT)"
  echo " STATUS: SUCCESS — full-update เสร็จสมบูรณ์"
  echo "========================"
  exit 0
fi

# --- พัง → exit 1 (ไม่ revert เอง) ---
# workflow: job 'frontend' fail → revert-frontend + revert-backend (image :prev)
# ★ DB ไม่ถูกถอยอัตโนมัติ (กันข้อมูลผู้ใช้ที่เขียนระหว่าง deploy หาย)
echo "========================"
echo " ❌ FRONTEND พัง (build/health) — exit 1"
echo "    → job revert-frontend + revert-backend จะคืน image :prev ให้ (DB ไม่ถูกถอยอัตโนมัติ)"
if [ -f /root/dormi-releases/snapshots/latest/MIGRATION_RAN ]; then
  echo "    ⚠️ รอบนี้มี migration — schema ล้ำหน้า code เก่า:"
  echo "       • additive (เพิ่ม column/table) → ปล่อยได้ code เก่ารันต่อได้"
  echo "       • destructive → ถอย DB เอง: gh workflow run revert-db.yml"
fi
echo " STATUS: FRONTEND FAILED"
echo "========================"
exit 1
