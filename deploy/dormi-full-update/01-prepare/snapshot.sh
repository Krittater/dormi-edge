#!/bin/bash
# 01-prepare/snapshot.sh — จับ "จุดกลับ" (rollback point) ของ FE/BE ก่อนเริ่ม deploy
# ------------------------------------------------------------------
# เก็บสิ่งที่ต้องใช้ revert "แอป" (FE/BE) ให้ทำได้จริงแบบไม่ต้อง build — ★ ไม่ยุ่ง DB
#   (DB backup เป็นหน้าที่ของ step1-migration ทำเฉพาะตอนมี migration จริง)
#   1. BE / FE commit เดิม               (ข้อมูลอ้างอิง + cross-check กับ /version)
#   2. ★ tag image ที่รันอยู่ไว้ (:prev)  → rollback = สลับ image เก่า ไม่ต้อง rebuild
#                                          (กัน image เก่าโดน docker image prune ทิ้ง)
#   3. ชื่อ migration ล่าสุด               → รู้ว่า schema อยู่เวอร์ชันไหน (อ่านเฉยๆ ไม่ backup)
# health check ผ่าน GET /version จริง (ไม่ใช่แค่ container up) → จุดกลับต้อง "ใช้งานได้จริง"
#
# ลำดับใน flow: หลัง 00-check/lockfile → ก่อน 02-deploy/step1-migration
# รันบน server:  bash snapshot.sh
# ต้องมี: git clones ของ FE/BE + container FE/BE/postgres รันอยู่
# หมายเหตุ: อ่าน + tag image เท่านั้น — ไม่แตะสภาพ app ที่รันอยู่ (ปลอดภัย)

set -euo pipefail

# ========= config =========
BE_DIR="/root/dormi-backend-2"
FE_DIR="/root/dormi-fe-2"
PG_CONTAINER="dormi_postgres"
SNAP_ROOT="/root/dormi-releases/snapshots"
KEEP=10

# container ที่รันจริง (ใช้ inspect หา image → tag เก็บไว้ให้ rollback)
BE_API_CONTAINER="docker-dormi-api-1"
BE_SCHED_CONTAINER="docker-dormi-scheduler-1"
FE_CONTAINER="dormi-fe-2-dormi-web-1"
BE_API_TAG="dormi-api:prev"
BE_SCHED_TAG="dormi-scheduler:prev"
FE_TAG="dormi-web:prev"

# /version สำหรับ health check + cross-check commit ที่รันจริง
API_HOST="dormi-api.dormi-linkandrent.com"
WEB_HOST="dormi-linkandrent.com"

TS="$(date +%Y%m%d-%H%M%S)"
SNAP_DIR="$SNAP_ROOT/$TS"

echo "========================"
echo " Snapshot — จุดกลับ (rollback point)"
echo " เวลา: $TS"
echo "========================"

# ---------- helpers ----------
running() { docker ps --format '{{.Names}}' | grep -q "^$1$"; }

# curl /version ผ่าน edge (force ไป localhost กัน hairpin/DNS) → เก็บ body ที่ $RESP
RESP=""
check_version() {  # $1=host $2=label
  RESP="$(curl -fsS --max-time 10 --resolve "$1:443:127.0.0.1" "https://$1/version" 2>/dev/null || true)"
  [ -n "$RESP" ] || { echo "❌ $2 /version ไม่ตอบ 200 — สภาพปัจจุบันไม่ควรใช้เป็นจุดกลับ"; return 1; }
}

# ดึง version จาก JSON (backend ถูก ResponseInterceptor ห่อ → data.version; frontend มีตรงๆ)
extract_version() { printf '%s' "$1" | grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4 || true; }

# tag image ของ container ให้เป็น rollback tag; echo image id (ว่าง = ไม่พบ)
snap_image() {
  local img
  img="$(docker inspect --format '{{.Image}}' "$1" 2>/dev/null || true)"
  [ -z "$img" ] && return 1
  docker tag "$img" "$2"
  printf '%s' "$img"
}

# ========= 0. validate — จุดกลับต้องมาจากสภาพที่ "ใช้งานได้จริง" =========
# 0a. container รันอยู่ (pre-check เร็ว ก่อนยิง curl)
for c in "$PG_CONTAINER" "$BE_API_CONTAINER" "$FE_CONTAINER"; do
  running "$c" || { echo "❌ container $c ไม่ได้รันอยู่ — ไม่ควรใช้เป็นจุดกลับ"; exit 1; }
done

# 0b. health check จริงผ่าน /version (พิสูจน์ว่า app ตอบ 200 ไม่ใช่แค่ container up)
check_version "$API_HOST" "backend"  || exit 1
API_BODY="$RESP"
check_version "$WEB_HOST" "frontend" || exit 1
WEB_BODY="$RESP"
API_RUN_VER="$(extract_version "$API_BODY")"
FE_RUN_VER="$(extract_version "$WEB_BODY")"
echo "🩺 health OK — /version: backend=${API_RUN_VER:-?} frontend=${FE_RUN_VER:-?}"

# 0c. git clones ต้องพร้อม (DB ไม่ยุ่ง — step1-migration จัดการ backup เอง ตอนมี migration)
[ -d "$BE_DIR/.git" ] || { echo "❌ ไม่พบ git repo ที่ $BE_DIR"; exit 1; }
[ -d "$FE_DIR/.git" ] || { echo "❌ ไม่พบ git repo ที่ $FE_DIR"; exit 1; }

mkdir -p "$SNAP_DIR"
cleanup_fail() { echo "↩️ ยกเลิก snapshot — ลบ $SNAP_DIR"; rm -rf "$SNAP_DIR"; }

# ========= 1. commit เดิม + cross-check กับ /version =========
BE_COMMIT="$(git -C "$BE_DIR" rev-parse HEAD)"; BE_SHORT="$(git -C "$BE_DIR" rev-parse --short HEAD)"
FE_COMMIT="$(git -C "$FE_DIR" rev-parse HEAD)"; FE_SHORT="$(git -C "$FE_DIR" rev-parse --short HEAD)"
echo "📌 BE commit: $BE_SHORT   FE commit: $FE_SHORT"

# git HEAD (clone ชี้) ควรตรงกับ /version (รันจริง) — ต่าง = pull แต่ยังไม่ deploy
# ("unknown" = ยังไม่เคย deploy ด้วย deploy.sh ที่ส่ง APP_VERSION → ข้าม cross-check)
if [ -n "$API_RUN_VER" ] && [ "$API_RUN_VER" != "unknown" ] && [ "$API_RUN_VER" != "$BE_SHORT" ]; then
  echo "⚠️  BE: git HEAD ($BE_SHORT) ≠ /version ($API_RUN_VER) — clone อาจ pull แต่ยังไม่ deploy (image :prev ยังตรงของจริง)"
fi
if [ -n "$FE_RUN_VER" ] && [ "$FE_RUN_VER" != "unknown" ] && [ "$FE_RUN_VER" != "$FE_SHORT" ]; then
  echo "⚠️  FE: git HEAD ($FE_SHORT) ≠ /version ($FE_RUN_VER) — clone อาจ pull แต่ยังไม่ deploy"
fi

# ========= 2. ★ tag image ที่รันอยู่ (แก่นของความรัดกุม) =========
echo "🏷️  tag image สำหรับ rollback..."
BE_API_IMG="$(snap_image "$BE_API_CONTAINER" "$BE_API_TAG" || true)"
FE_IMG="$(snap_image "$FE_CONTAINER" "$FE_TAG" || true)"
BE_SCHED_IMG="$(snap_image "$BE_SCHED_CONTAINER" "$BE_SCHED_TAG" || true)"

if [ -z "$BE_API_IMG" ] || [ -z "$FE_IMG" ]; then
  echo "❌ หา image ของ api/web ไม่เจอ — rollback แบบไม่ต้อง build จะทำไม่ได้"
  cleanup_fail; exit 1
fi
echo "   api → $BE_API_TAG   web → $FE_TAG$([ -n "$BE_SCHED_IMG" ] && echo "   scheduler → $BE_SCHED_TAG")"
[ -z "$BE_SCHED_IMG" ] && echo "   ⚠️ ไม่พบ scheduler container — ข้าม (rollback scheduler ต้อง build)"

# ========= 3. migration ล่าสุด (schema เวอร์ชันไหน) =========
LAST_MIGRATION="$(docker exec "$PG_CONTAINER" sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT name FROM migrations ORDER BY timestamp DESC LIMIT 1"' 2>/dev/null | tr -d '[:space:]' || true)"
echo "🧬 migration ล่าสุด: ${LAST_MIGRATION:-<อ่านไม่ได้>}"

# ========= 4. เขียน manifest =========
cat > "$SNAP_DIR/snapshot.env" <<EOF
# Snapshot จุดกลับ (FE/BE) — สร้างโดย 01-prepare/snapshot.sh ($TS)
# step rollback source ไฟล์นี้เพื่อรู้ว่า "ของเดิม" คืออะไร (ไม่มี DB — ดู MIGRATION_RAN แทน)
SNAPSHOT_TS=$TS

# --- commit ---
BE_COMMIT=$BE_COMMIT
FE_COMMIT=$FE_COMMIT
# commit ที่รันจริง (จาก /version) — ความจริงหลัก ("unknown" = ยังไม่ได้ deploy ด้วย APP_VERSION)
BE_RUNNING_VERSION=$API_RUN_VER
FE_RUNNING_VERSION=$FE_RUN_VER

# --- image สำหรับ rollback แบบไม่ต้อง build (แก่น) ---
BE_API_IMAGE=$BE_API_IMG
BE_API_ROLLBACK_TAG=$BE_API_TAG
BE_SCHED_IMAGE=${BE_SCHED_IMG:-}
BE_SCHED_ROLLBACK_TAG=$BE_SCHED_TAG
FE_IMAGE=$FE_IMG
FE_ROLLBACK_TAG=$FE_TAG

# --- migration (อ้างอิงเฉยๆ — ไม่มี DB backup ที่นี่) ---
LAST_MIGRATION=$LAST_MIGRATION
EOF

# ========= 5. ตัวชี้ latest + rotate =========
ln -sfn "$SNAP_DIR" "$SNAP_ROOT/latest"
{ ls -1dt "$SNAP_ROOT"/2*/ 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf; } || true

echo "========================"
echo " ✅ SNAPSHOT READY"
echo " ที่เก็บ  : $SNAP_DIR"
echo " latest   : $SNAP_ROOT/latest  (→ $TS)"
echo " จุดกลับ  : BE=$BE_SHORT  FE=$FE_SHORT  image tagged :prev (ไม่ยุ่ง DB)"
echo " ถัดไป    : set -a && . $SNAP_ROOT/latest/snapshot.env && set +a"
echo "========================"
