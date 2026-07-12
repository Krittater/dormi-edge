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
# แล้ว sync เฉพาะไฟล์พวกนี้เข้า git (edge repo) แบบ best-effort
#
# ใช้:  bash step4-version-manager.sh [X.Y.Z]
set -uo pipefail

# ========= config =========
BE_DIR="/root/dormi-backend-2"
FE_DIR="/root/dormi-fe-2"
PG_CONTAINER="dormi_postgres"

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

# ========= 3. เก็บข้อมูล release (commit ที่ deploy จริง + schema) =========
BE_SHA="$(git -C "$BE_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
FE_SHA="$(git -C "$FE_DIR" rev-parse --short HEAD 2>/dev/null || echo '?')"
MIGRATION="$(docker exec "$PG_CONTAINER" sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT name FROM migrations ORDER BY timestamp DESC LIMIT 1"' 2>/dev/null | tr -d '[:space:]' || true)"
[ -z "$MIGRATION" ] && MIGRATION="?"
TS="$(date '+%Y-%m-%d %H:%M:%S')"
LINE="v$NEW | $TS | be=$BE_SHA fe=$FE_SHA | migration=$MIGRATION | $MODE"

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
