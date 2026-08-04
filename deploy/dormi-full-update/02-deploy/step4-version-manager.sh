#!/bin/bash
# 02-deploy/step4-version-manager.sh — ประทับ "release version" หลัง deploy สำเร็จครบ stack
# ------------------------------------------------------------------
# ทำเมื่อ FE+BE deploy สำเร็จแล้ว (job สุดท้าย needs: frontend) — งานบันทึกอย่างเดียว
# ★ ไม่ revert / ไม่กระทบ deploy: deploy สำเร็จไปแล้ว push log พังก็แค่เตือน
#
# version:
#   - ไม่ใส่ arg → auto +0.0.1 (patch) จากเลขเดิม   เช่น 0.1.3 → 0.1.4
#   - ใส่ arg    → override ระบุเอง (X.Y.Z)          เช่น bash step4... 0.2.0
#
# ที่เก็บ (ตัวจริง = server file):
#   /root/dormi-releases/VERSION       เลขปัจจุบัน บรรทัดเดียว
#   /root/dormi-releases/RELEASES.log  ประวัติ append-only (ผูก version↔be↔fe↔migration)
#     ★ be=/fe= อ่านจาก GET /version (ของที่รันจริง) — ไม่ใช่ git HEAD ของ clone
#       ค่าที่ขึ้นต้นด้วย '~' = อ่าน /version ไม่ได้ จึง fallback ไป git HEAD (ไม่ยืนยัน)
# แล้ว sync เฉพาะไฟล์พวกนี้เข้า git (edge repo) แบบ best-effort
#
# ใช้:  bash step4-version-manager.sh [X.Y.Z]
set -uo pipefail

# ========= config =========
BE_DIR="/root/dormi-backend-2"
FE_DIR="/root/dormi-fe-2"
PG_CONTAINER="dormi_postgres"

# ★ ความจริงของ "อะไรรันอยู่จริง" มาจาก GET /version ไม่ใช่ git HEAD ของ clone
#   (clone อาจค้างเพราะ fetch ไม่ผ่าน → git HEAD หลอกได้ · เคยทำ log ผิดมาแล้ว v1.0.13/v1.0.14)
API_HOST="dormi-api.dormi-linkandrent.com"
WEB_HOST="dormi-linkandrent.com"
# frontend อยู่ใต้ basePath /app — backend ยังอยู่ที่ /version เหมือนเดิม
# ★ ลองทั้งสองทาง เผื่อของที่รันอยู่เป็น image ก่อนมี basePath (deploy รอบแรก / หลัง revert)
WEB_VERSION_PATHS="/app/version /version"

REL_DIR="/root/dormi-releases"
VERSION_FILE="$REL_DIR/VERSION"
LOG_FILE="$REL_DIR/RELEASES.log"

# git sync (auto push เฉพาะไฟล์ releases/)
EDGE_DIR="/root/dormi-edge"
EDGE_BRANCH="main"
EDGE_REL_DIR="$EDGE_DIR/releases"
GIT_NAME="dormi-deploy-bot"
GIT_EMAIL="deploy@dormi-linkandrent.com"

OVERRIDE="${1:-}"          # มี arg = ระบุ version เอง; ว่าง = auto
# scope ของรอบนี้ (all/backend/frontend) — workflow ส่งมาเป็น arg 2 หรือ env DEPLOY_SCOPE
# บันทึกลง log ด้วย: deploy ฝั่งเดียวแล้วบันทึกทั้ง be= และ fe= ทำให้อ่านเหมือน deploy ครบ stack
SCOPE="${2:-${DEPLOY_SCOPE:-all}}"

echo "========================"
echo " Step 4 — Version manager (บันทึก release)"
echo "========================"

mkdir -p "$REL_DIR"

# ========= 1. อ่าน version ปัจจุบัน =========
CURRENT="$(tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null || true)"
[ -z "$CURRENT" ] && CURRENT="0.0.0"    # ครั้งแรกสุด

# ========= 2. คำนวณ version ใหม่ (override > auto patch) =========
if [ -n "$OVERRIDE" ]; then
  NEW="${OVERRIDE#v}"                   # ตัด v นำหน้าถ้ามี
  if ! printf '%s' "$NEW" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "❌ version '$OVERRIDE' ไม่ใช่รูปแบบ X.Y.Z — ยกเลิก (deploy สำเร็จแล้ว ไม่กระทบ)"
    echo " STATUS: SKIP (bad input)"
    exit 1
  fi
  MODE="manual"
else
  # auto: bump patch จากเลขเดิม
  IFS='.' read -r MA MI PA <<EOF
$CURRENT
EOF
  case "${MA}${MI}${PA}" in
    ''|*[!0-9]*) echo "⚠️ VERSION เดิม ('$CURRENT') อ่านไม่ได้ — เริ่มที่ 0.0.1"; MA=0; MI=0; PA=0 ;;
  esac
  NEW="${MA}.${MI}.$((PA + 1))"
  MODE="auto"
fi
echo "🔖 $CURRENT → v$NEW ($MODE)"

# ========= 3. เก็บข้อมูล release (commit ที่ "รันอยู่จริง" + schema) =========
# อ่าน commit ที่รันจริงจาก GET /version (backend ถูก ResponseInterceptor ห่อ → data.version)
# ว่าง = อ่านไม่ได้
running_version() {  # $1=host  $2=รายการ path คั่นช่องว่าง (ไม่ใส่ = /version)
  local p v
  for p in ${2:-/version}; do
    v="$(curl -fsS --max-time 10 --resolve "$1:443:127.0.0.1" "https://$1$p" 2>/dev/null \
      | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true)"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}

# ★ บันทึกจาก /version เป็นหลัก — git HEAD ของ clone เชื่อไม่ได้
#   (clone ค้างเพราะ fetch พัง → เคยบันทึก fe=3e35942 ซ้ำ 2 รอบทั้งที่ FE ไม่ได้ deploy)
#   อ่าน /version ไม่ได้ → fallback git HEAD แต่ใส่ '~' นำหน้า = "ไม่ได้ยืนยันจากของที่รันจริง"
resolve_sha() {  # $1=host  $2=repo-dir  $3=รายการ path (ไม่ใส่ = /version)
  local v
  v="$(running_version "$1" "${3:-}")"
  if [ -n "$v" ] && [ "$v" != "unknown" ]; then printf '%s' "$v"; return 0; fi
  printf '~%s' "$(git -C "$2" rev-parse --short HEAD 2>/dev/null || echo '?')"
}

BE_SHA="$(resolve_sha "$API_HOST" "$BE_DIR")"
FE_SHA="$(resolve_sha "$WEB_HOST" "$FE_DIR" "$WEB_VERSION_PATHS")"
case "$BE_SHA$FE_SHA" in
  *'~'*) echo "⚠️ บาง service อ่าน /version ไม่ได้ — ค่าที่ขึ้นต้นด้วย ~ มาจาก git HEAD (ไม่ยืนยัน)" ;;
esac
MIGRATION="$(docker exec "$PG_CONTAINER" sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT name FROM migrations ORDER BY timestamp DESC LIMIT 1"' 2>/dev/null | tr -d '[:space:]' || true)"
[ -z "$MIGRATION" ] && MIGRATION="?"
TS="$(date '+%Y-%m-%d %H:%M:%S')"
LINE="v$NEW | $TS | be=$BE_SHA fe=$FE_SHA | migration=$MIGRATION | scope=$SCOPE | $MODE"

# ========= 4. เขียน server file (ตัวจริง) — atomic สำหรับ VERSION =========
printf '%s\n' "$NEW" > "$VERSION_FILE.tmp" && mv "$VERSION_FILE.tmp" "$VERSION_FILE"
printf '%s\n' "$LINE" >> "$LOG_FILE"
echo "✅ บันทึกลง server แล้ว: $LOG_FILE"
echo "   $LINE"

# ========= 5. sync เข้า git (best-effort — เฉพาะ releases/) =========
# push พังไม่ทำให้ deploy พัง: ของจริงอยู่ server แล้ว, sync มือทีหลังได้
sync_git() {
  [ -d "$EDGE_DIR/.git" ] || { echo "⚠️ ไม่พบ git repo ที่ $EDGE_DIR — ข้าม push"; return 1; }
  local i
  for i in 1 2 3; do
    # sync กับ remote ก่อน (กัน push ชน) — reset ปลอดภัยเพราะของจริงอยู่ $REL_DIR
    git -C "$EDGE_DIR" fetch -q origin "$EDGE_BRANCH" || { echo "  ⚠️ fetch ไม่ได้"; return 1; }
    git -C "$EDGE_DIR" reset -q --hard "origin/$EDGE_BRANCH" || return 1

    mkdir -p "$EDGE_REL_DIR"
    cp "$VERSION_FILE" "$EDGE_REL_DIR/VERSION"
    cp "$LOG_FILE"     "$EDGE_REL_DIR/RELEASES.log"
    git -C "$EDGE_DIR" add "releases/VERSION" "releases/RELEASES.log" || return 1

    if git -C "$EDGE_DIR" diff --cached --quiet; then
      echo "ℹ️ releases/ ตรงกับ git อยู่แล้ว — ไม่ต้อง commit"
      return 0
    fi

    git -C "$EDGE_DIR" \
      -c user.name="$GIT_NAME" -c user.email="$GIT_EMAIL" \
      commit -q -m "chore(release): record v$NEW (be=$BE_SHA fe=$FE_SHA)" || return 1

    if git -C "$EDGE_DIR" push -q origin "HEAD:$EDGE_BRANCH"; then
      return 0
    fi
    echo "  ↻ push ชน/ล้มเหลว (รอบ $i) — sync ใหม่แล้วลองอีก"
  done
  return 1
}

if sync_git; then
  echo "✅ push release log เข้า git สำเร็จ (เฉพาะ releases/ — commit: chore(release))"
else
  echo "⚠️ push เข้า git ไม่สำเร็จ (สิทธิ์ push? / network?) — แต่บันทึกบน server แล้ว ไม่กระทบ deploy"
  echo "   sync มือทีหลัง:"
  echo "     cp $VERSION_FILE $LOG_FILE $EDGE_REL_DIR/ && \\"
  echo "     git -C $EDGE_DIR add releases/ && git -C $EDGE_DIR commit -m 'chore(release): record v$NEW' && git -C $EDGE_DIR push"
fi

echo "========================"
echo " ✅ RELEASE บันทึกแล้ว: v$NEW"
echo " STATUS: SUCCESS"
echo "========================"
exit 0
