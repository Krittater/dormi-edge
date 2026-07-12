#!/bin/bash
# run-all.sh — orchestrator (local): รัน full-update ตามลำดับ + เรียก revert เมื่อพัง
# ------------------------------------------------------------------
# ทางเลือกของ .github/workflows/full-update.yml สำหรับรันตรงบน server (ไม่ผ่าน GitHub)
# ตรรกะ revert เหมือน workflow เป๊ะ — เพราะ step ไม่ revert เองแล้ว (revert scripts self-sufficient):
#   - step ไหนพัง → run-all เรียก revert ตาม scope (เหมือน job revert-* ใน workflow)
#   - revert0 เช็ค marker เอง (ไม่มี migration = ข้าม DB)
#   - revert1/2 อ่าน snapshot.env เอง (image :prev)
#
# ลำดับ:
#   1. check lockfile   พัง → หยุด (ยังไม่ deploy)
#   2. snapshot         พัง → หยุด
#   3. migration        พัง → revert DB (อัตโนมัติ — ยังไม่มี traffic บน schema ใหม่)
#   4. backend          พัง → revert BE            (★ DB ไม่ถอยอัตโนมัติ)
#   5. frontend         พัง → revert FE + BE       (★ DB ไม่ถอยอัตโนมัติ)
#   ★ DB revert กรณี 4/5 = ตัดสินใจมือ (bash 03-revert/revert0-restore-db.sh หรือ revert-db.yml)
#     เหตุผล: restore จะลบข้อมูลที่ผู้ใช้เขียนระหว่าง deploy — additive migration ไม่ต้องถอย DB
#
# รันบน server:  bash run-all.sh [X.Y.Z]
#   ใส่ X.Y.Z = override release version ; เว้นว่าง = auto +0.0.1
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VERSION_OVERRIDE="${1:-}"      # ส่งต่อให้ step4 (ว่าง = auto)
R0="$HERE/03-revert/revert0-restore-db.sh"
R1="$HERE/03-revert/revert1-deploy-backend-old-version.sh"
R2="$HERE/03-revert/revert2-deploy-frontend-old-version.sh"

MARKER="/root/dormi-releases/snapshots/latest/MIGRATION_RAN"

# บอกทางเลือก DB revert แบบมือ (นโยบาย: BE/FE พังไม่ถอย DB อัตโนมัติ — กันข้อมูลหาย)
db_manual_note() {
  if [ -f "$MARKER" ]; then
    echo "⚠️ รอบนี้มี migration (marker) — DB ไม่ถูกถอยอัตโนมัติ (กันข้อมูลผู้ใช้ระหว่าง deploy หาย)"
    echo "   • migration แบบ additive → ปล่อยได้ code เก่ารันต่อได้"
    echo "   • ถ้า destructive และต้องถอย DB จริง: bash $R0"
  fi
}

# ตัวจัดการ revert ต่อ step (เรียง FE→BE เหมือน workflow · DB = migration fail เท่านั้น)
revert_none()     { echo "ℹ️ ยังไม่ deploy อะไร — ไม่ต้อง revert"; }
revert_migration(){ bash "$R0"; }
revert_backend()  { bash "$R1"; db_manual_note; }
revert_frontend() { bash "$R2"; bash "$R1"; db_manual_note; }

run_step() {  # $1=label  $2=script(relative)  $3=revert-handler
  echo
  echo "########################################"
  echo "# ▶ $1"
  echo "########################################"
  if ! bash "$HERE/$2"; then
    echo
    echo "########################################"
    echo "# ❌ FULL-UPDATE หยุดที่: $1 — เริ่ม revert"
    echo "########################################"
    "$3"
    echo
    echo "########################################"
    echo "# ↩️ revert เสร็จ (ดูสถานะ SUCCESS/FAILED/SKIP ด้านบน)"
    echo "########################################"
    exit 1
  fi
}

echo "════════════════════════════════════════"
echo " FULL-UPDATE เริ่ม — $(date '+%Y-%m-%d %H:%M:%S')"
echo "════════════════════════════════════════"

run_step "1. Check lockfile (FE + BE)"          "00-check/check0-lockfile-match.sh"   revert_none
run_step "2. Snapshot (จุดกลับ FE/BE)"           "01-prepare/snapshot.sh"              revert_none
run_step "3. Migration (diff → backup → run)"    "02-deploy/step1-migration-run.sh"    revert_migration
run_step "4. Deploy backend"                     "02-deploy/step2-backend-deploy.sh"   revert_backend
run_step "5. Deploy frontend"                    "02-deploy/step3-frontend-deploy.sh"  revert_frontend

# 6. บันทึก release version — deploy สำเร็จแล้ว งานบันทึกอย่างเดียว
#    ★ ไม่ผ่าน run_step (ไม่ revert) — push log พังก็ไม่ถอย deploy ที่สำเร็จ
echo
echo "########################################"
echo "# ▶ 6. Record release version"
echo "########################################"
bash "$HERE/02-deploy/step4-version-manager.sh" "$VERSION_OVERRIDE" \
  || echo "⚠️ version manager มีปัญหา (deploy สำเร็จแล้ว — ไม่กระทบ)"

echo
echo "════════════════════════════════════════"
echo " ✅ FULL-UPDATE สำเร็จทั้งหมด"
echo "════════════════════════════════════════"
