#!/bin/bash
# deploy/lib/deploy-lock.sh — กันสองสาย deploy ชนกันบน server เดียวกัน
# ------------------------------------------------------------------
# ทำไมต้องมี:
#   GitHub Actions `concurrency:` คุมได้เฉพาะ "ภายใน repo เดียวกัน" เท่านั้น
#     • full-update      (edge repo)     group = full-update
#     • hotfix backend   (backend repo)  group = deploy-production-backend
#   → คนละ repo = คนละ scope → GitHub ปล่อยให้รันพร้อมกันได้
#   → แต่ทั้งคู่ SSH เข้า server ตัวเดียวกันแล้วสั่ง docker compose บน project เดียวกัน
#     = build/recreate ทับกันกลางคัน, image :prev โดนสลับผิดตัว, /version สับสน
#
# วิธีแก้: lock ที่ filesystem ของ server — จุดร่วมจริงของทั้ง 2 สาย (ไม่ต้องพึ่ง GitHub)
#
# ใช้:
#   . "<edge>/deploy/lib/deploy-lock.sh"
#   deploy_lock "ชื่องาน"
#
#   ได้ lock  → ไปต่อ
#   ไม่ได้ใน DEPLOY_LOCK_WAIT วินาที → exit 1 พร้อมบอกว่าใครถืออยู่
#
# lock ปล่อยอัตโนมัติเมื่อ process จบ (fd 9 ปิดเอง) → ไม่มี lock ค้างแม้สคริปต์พังกลางทาง
# ปรับได้ด้วย env: DEPLOY_LOCK_FILE, DEPLOY_LOCK_WAIT

DEPLOY_LOCK_FILE="${DEPLOY_LOCK_FILE:-/var/lock/dormi-deploy.lock}"
DEPLOY_LOCK_WAIT="${DEPLOY_LOCK_WAIT:-300}"   # วินาที (5 นาที)

deploy_lock() {  # $1=ชื่องาน (ไปโผล่ในข้อความฝั่งที่รอ)
  local label="${1:-deploy}" holder

  # แยกเคส "ไม่มี flock" ออกจาก "lock ไม่ว่าง" — ไม่งั้นจะฟ้องผิดสาเหตุแล้วไล่หาผิดจุด
  # (fail-closed: ล็อกไม่ได้ = ไม่ deploy ดีกว่าเสี่ยงชนกัน)
  if ! command -v flock >/dev/null 2>&1; then
    echo "❌ ไม่พบคำสั่ง flock บนเครื่องนี้ — ล็อกกันชนไม่ได้ จึงไม่ deploy ต่อ"
    echo "   ติดตั้ง: apt-get install -y util-linux   (Debian/Ubuntu มีมาให้อยู่แล้วตามปกติ)"
    exit 1
  fi

  # ★ ใช้ 9<> (read-write) ไม่ใช่ 9> — เพราะ `9>` ล้างไฟล์ทิ้งตั้งแต่ตอนเปิด
  #   ฝั่งที่มา "รอ" ก็เปิดไฟล์เหมือนกัน → จะไปล้างข้อมูลผู้ถือ lock ทิ้งก่อนได้อ่าน
  #   (ทดสอบแล้ว: ใช้ 9> จะขึ้น "ผู้ถือ lock: <อ่านไม่ได้>" เสมอ)
  exec 9<>"$DEPLOY_LOCK_FILE" || {
    echo "❌ เปิด lock file ไม่ได้: $DEPLOY_LOCK_FILE"
    exit 1
  }

  if flock -w "$DEPLOY_LOCK_WAIT" 9; then
    # ได้ lock แล้วค่อยเขียนทับ (ปลอดภัย เพราะไม่มีใครแข่งตอนนี้)
    printf '%s | pid=%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" "$label" > "$DEPLOY_LOCK_FILE"
    return 0
  fi

  holder="$(cat "$DEPLOY_LOCK_FILE" 2>/dev/null || true)"
  echo "❌ มี deploy อื่นทำงานอยู่ — รอ ${DEPLOY_LOCK_WAIT}s แล้วยังไม่ว่าง จึงยกเลิก"
  echo "   ผู้ถือ lock ล่าสุด: ${holder:-<อ่านไม่ได้>}"
  echo "   full-update กับ hotfix ของ repo แอป ห้ามรันพร้อมกัน (docker compose จะชนกัน)"
  echo "   → รอให้อีกสายจบแล้วสั่งใหม่ · ถ้าแน่ใจว่าไม่มีใครรัน: rm -f $DEPLOY_LOCK_FILE"
  exit 1
}
