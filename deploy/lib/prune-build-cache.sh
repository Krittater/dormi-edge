#!/bin/bash
# deploy/lib/prune-build-cache.sh — ล้าง build cache ของ Docker หลัง deploy สำเร็จ
# ------------------------------------------------------------------
# ทำไมต้องมี:
#   ทุกครั้งที่ build image บน server (full-update, admin-release) Docker เก็บ build cache
#   ไว้ ~0.5–1 GB ต่อรอบ และไม่เคยลบเอง → 29 ต.ค. 2026 สะสมถึง 13.9 GB (ดิสก์โตเร็วผิดปกติ)
#
# ทำอะไร: ลบเฉพาะ cache ที่ไม่ได้ใช้เกิน DORMI_BUILD_CACHE_KEEP (ค่าเริ่มต้น 72h)
#   → deploy รอบถัดไปใน 3 วันยังได้ cache (build เร็วเหมือนเดิม)
#   ไม่แตะ image ที่มีชื่อ (:prev, release-*) และ container/volume ใดๆ
#
# ใช้ (เรียกหลัง deploy สำเร็จเท่านั้น):
#   . "<edge>/deploy/lib/prune-build-cache.sh"
#   prune_build_cache
#
# ไม่ทำให้ deploy ล้มเด็ดขาด: พังอะไรก็แค่เตือนแล้วไปต่อ

DORMI_BUILD_CACHE_KEEP="${DORMI_BUILD_CACHE_KEEP:-72h}"

prune_build_cache() {
  local out
  if ! out=$(docker builder prune -f --filter "until=${DORMI_BUILD_CACHE_KEEP}" 2>&1); then
    echo "⚠️ ล้าง build cache ไม่สำเร็จ (ไม่กระทบ deploy): $(printf '%s' "$out" | tail -1)"
    return 0
  fi
  echo "🧹 ล้าง build cache เก่ากว่า ${DORMI_BUILD_CACHE_KEEP}: $(printf '%s' "$out" | tail -1)"
  df -h / 2>/dev/null | awk 'NR==2 {print "   ดิสก์: ใช้ " $3 " / " $2 " (" $5 ")"}' || true
  return 0
}
