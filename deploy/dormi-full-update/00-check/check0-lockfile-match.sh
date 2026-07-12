#!/bin/bash
# 01-check/check0-lockfile-match.sh — เช็ค package-lock.json sync ทั้ง frontend + backend
# ------------------------------------------------------------------
# เหมือน CI check บน GitHub (รัน npm ci บน linux) แต่ทำบน server ก่อน deploy
#   - lock เพี้ยน (npm บน Windows ตัด optional deps ของ linux เช่น @emnapi) = build พังตอน deploy
#   - เช็คก่อน → หยุดก่อนถึง deploy + บอกได้ว่า "ฝั่งไหน" mismatch
#
# วิธี: ดึง package.json + lock ของ commit เป้าหมาย (origin) ออกมาใส่ temp (ไม่แตะ clone)
#       แล้วรัน `npm ci --dry-run` ใน node:22-alpine (image เดียวกับ Docker build)
#       → sync check ของ npm ci จะ fail ถ้า lock ไม่ตรง package.json
#
# รันบน server:  bash check0-lockfile-match.sh
# ต้องมี: git clones ของ FE/BE + docker
# exit 0 = sync ทั้งคู่ / exit 1 = มีฝั่ง mismatch

set -uo pipefail   # ไม่ใช้ -e — ต้องเก็บผลทั้ง 2 ฝั่งก่อนสรุป

# ========= config =========
BE_DIR="/root/dormi-backend-2"; BE_BRANCH="master"
FE_DIR="/root/dormi-fe-2";      FE_BRANCH="main"
IMAGE="node:22-alpine"

echo "========================"
echo " Check — lockfile sync (npm ci บน linux)"
echo "========================"

# เช็ค lock ของ 1 repo ; return 0=sync 1=mismatch/error
check_lock() {   # $1=dir  $2=branch  $3=label
  local dir="$1" branch="$2" label="$3" ref tmp rc

  if [ ! -d "$dir/.git" ]; then
    echo "❌ [$label] ไม่พบ git repo ที่ $dir"
    return 1
  fi

  # fetch เป้าหมายล่าสุด → เช็ค lock ของ "code ที่กำลังจะ deploy" (ไม่ใช่ของเก่าใน clone)
  ref="origin/$branch"
  if ! git -C "$dir" fetch -q origin "$branch" 2>/dev/null; then
    echo "⚠️  [$label] fetch origin/$branch ไม่สำเร็จ — เช็คจาก HEAD ปัจจุบันแทน"
    ref="HEAD"
  fi

  # ดึงแค่ 2 ไฟล์ออกมาใส่ temp (ไม่แตะ working tree ของ clone)
  tmp="$(mktemp -d)"
  if ! git -C "$dir" show "$ref:package.json"      > "$tmp/package.json"      2>/dev/null \
    || ! git -C "$dir" show "$ref:package-lock.json" > "$tmp/package-lock.json" 2>/dev/null; then
    echo "❌ [$label] อ่าน package.json / package-lock.json จาก $ref ไม่ได้"
    rm -rf "$tmp"
    return 1
  fi

  # npm ci --dry-run: sync check จะ error ทันทีถ้า lock ไม่ตรง (ก่อนติดตั้งจริง)
  docker run --rm -v "$tmp:/app" -w /app "$IMAGE" \
    npm ci --dry-run --ignore-scripts --no-audit --no-fund >/dev/null 2>&1
  rc=$?

  rm -rf "$tmp"
  return $rc
}

# ========= เช็คทั้ง 2 ฝั่ง (เก็บผลก่อน แล้วค่อยสรุป) =========
BE_RESULT="OK"; FE_RESULT="OK"

echo "🔎 backend  ($BE_BRANCH)..."
check_lock "$BE_DIR" "$BE_BRANCH" "backend"  || BE_RESULT="MISMATCH"

echo "🔎 frontend ($FE_BRANCH)..."
check_lock "$FE_DIR" "$FE_BRANCH" "frontend" || FE_RESULT="MISMATCH"

# ========= สรุป =========
echo "------------------------"
echo " backend  : $BE_RESULT"
echo " frontend : $FE_RESULT"
echo "------------------------"

if [ "$BE_RESULT" = "MISMATCH" ] || [ "$FE_RESULT" = "MISMATCH" ]; then
  echo "❌ LOCKFILE MISMATCH — deploy จะพังตอน build (npm ci)"
  echo "   วิธีแก้: ไปที่ฝั่งที่ MISMATCH บนเครื่อง dev แล้ว:"
  [ "$BE_RESULT" = "MISMATCH" ] && echo "     • backend  → npm run lockfile → git add package-lock.json → commit → push"
  [ "$FE_RESULT" = "MISMATCH" ] && echo "     • frontend → npm run lockfile → git add package-lock.json → commit → push"
  echo "   แล้วค่อยเริ่ม full-update ใหม่"
  exit 1
fi

echo "✅ lockfile sync ทั้ง 2 ฝั่ง — deploy build ผ่านแน่"
exit 0
