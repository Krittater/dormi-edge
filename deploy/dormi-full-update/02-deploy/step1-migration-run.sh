#!/bin/bash
# 02-deploy/step1-migration-run.sh — รัน migration (ไม่ revert เอง — workflow เรียก revert)
# ------------------------------------------------------------------
# 1. หา migration ที่ต้องรันจริง: git diff (--diff-filter=A เฉพาะไฟล์เพิ่มใหม่)
#    + เช็คกับตาราง migrations ใน DB (ความจริงสุดท้าย) — ไม่มี pending = ข้าม
# 2. มี pending → เรียก 01-prepare/backup.sh (backup ทั้งก้อนก่อน)
# 3. เขียน marker (ก่อน migrate) = "รอบนี้แตะ schema" + เก็บ path backup
# 4. รัน migration → พัง = exit 1 (job 'revert-db' ใน workflow จะ restore เอง โดยอ่าน marker)
#
# รันบน server (ผ่าน job 'migration'):  bash step1-migration-run.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BACKUP_SH="$HERE/../01-prepare/backup.sh"

# ========= config =========
BE_DIR="/root/dormi-backend-2"
BE_BRANCH="master"
MIGRATION_DIR="src/database/migrations"
MIGRATE_IMAGE="dormi-migrate:latest"
COMPOSE_DIR="docker"
ENV_FILE=".env.production"
BACKUP_DIR="/root/dormi-releases/db-backups"
# marker: เขียนเมื่อ migrate สำเร็จ → step2/3 อ่านเพื่อรู้ว่าต้อง revert DB ด้วยมั้ย
#   (เก็บ path backup ไว้ในไฟล์ด้วย → revert ใช้ backup ตัวเป๊ะของ release นี้)
MARKER="/root/dormi-releases/snapshots/latest/MIGRATION_RAN"

echo "========================"
echo " Step 1 — Migration"
echo "========================"

[ -d "$BE_DIR/.git" ] || { echo "❌ ไม่พบ git repo ที่ $BE_DIR"; exit 1; }

# ========= 1. หา migration ที่ต้องรันจริง — DB คือความจริงสุดท้าย ไม่ใช่ git =========
if ! git -C "$BE_DIR" fetch -q origin "$BE_BRANCH"; then
  echo "❌ fetch origin/$BE_BRANCH ไม่สำเร็จ"; exit 1
fi

# 1a. git diff แบบ "เพิ่มใหม่จริงเท่านั้น" (--diff-filter=A + .ts)
#     ตรงกติกา: migration สร้างไฟล์ใหม่เสมอ ห้ามแก้ของเก่า — แก้/ลบไฟล์เก่าไม่นับว่ามี migration
MIG_ADDED="$(git -C "$BE_DIR" diff --name-only --diff-filter=A HEAD "origin/$BE_BRANCH" -- "$MIGRATION_DIR" 2>/dev/null | grep -E '\.ts$' || true)"

# 1b. ★ เช็คกับ DB จริง (ปิด H2): เทียบ "ทุกไฟล์ migration ใน origin" กับตาราง migrations
#     git state หลอกได้ (เช่น clone ถูก reset ไป commit ใหม่ แล้ว DB ถูก revert กลับ)
#     แต่ตาราง migrations ใน DB ไม่หลอก — ไฟล์ไหนไม่อยู่ในตาราง = ยังไม่ apply = ต้องรัน
#     (ชื่อใน DB = <Name><timestamp> เช่น InitialSchema1783266277045 ← ไฟล์ <timestamp>-<Name>.ts)
ALL_FILES="$(git -C "$BE_DIR" ls-tree -r --name-only "origin/$BE_BRANCH" -- "$MIGRATION_DIR" 2>/dev/null | grep -E '\.ts$' || true)"
APPLIED="$(docker exec dormi_postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT name FROM migrations"' 2>/dev/null || true)"

PENDING=""
for f in $ALL_FILES; do
  base="${f##*/}"; base="${base%.ts}"     # 1783266277045-InitialSchema
  ts="${base%%-*}"; nm="${base#*-}"       # → class ใน DB: InitialSchema1783266277045
  cls="${nm}${ts}"
  printf '%s\n' "$APPLIED" | grep -qx "$cls" || PENDING="${PENDING}${f}"$'\n'
done
PENDING="$(printf '%s' "$PENDING")"

if [ -z "$PENDING" ]; then
  echo "✅ migration ทุกไฟล์ apply ใน DB ครบแล้ว → ข้าม step นี้"
  [ -n "$MIG_ADDED" ] && echo "   (git diff เห็นไฟล์เพิ่มใหม่ แต่ DB มีแล้ว — apply ไปก่อนหน้า)"
  exit 0
fi

echo "🔄 พบ migration ที่ DB ยังไม่มี (= ต้องรัน + backup ก่อน):"
echo "$PENDING" | sed 's/^/   • /'
if [ -z "$MIG_ADDED" ]; then
  echo "   ⚠️ git diff ไม่เห็นไฟล์เพิ่มใหม่ แต่ DB ยังไม่ apply — เคสหลัง revert DB"
  echo "      → เดินหน้าแบบเต็มวงจร (backup + marker) เพื่อความปลอดภัย"
fi

# ========= 2. backup ก่อน (เรียก 00-prepare/backup.sh) =========
echo "📦 เรียก backup ก่อน migrate..."
if ! bash "$BACKUP_SH"; then
  echo "❌ backup ล้มเหลว — ยกเลิก (ไม่ migrate โดยไม่มี backup เด็ดขาด)"
  exit 1
fi
BACKUP_FILE="$(ls -1t "$BACKUP_DIR"/*.dump 2>/dev/null | head -1 || true)"
if [ -z "$BACKUP_FILE" ]; then
  echo "❌ หา backup ที่เพิ่งสร้างไม่เจอ — ยกเลิก"
  exit 1
fi
echo "   ↳ backup: $BACKUP_FILE"

# ========= 3. pull clone ไป target + build migration runner =========
# ต้อง pull เพื่อให้ไฟล์ migration ใหม่อยู่ใน clone (build runner จะได้เห็น)
git -C "$BE_DIR" reset --hard "origin/$BE_BRANCH"

echo "🏗️  build migration runner (build stage — มี ts-node + src)..."
if ! docker build --target build -t "$MIGRATE_IMAGE" "$BE_DIR"; then
  echo "❌ build runner ล้มเหลว (code ใหม่ compile ไม่ผ่าน?) — ยังไม่ได้แตะ DB, ยกเลิก"
  exit 1
fi

# ========= 4. เขียน marker "ก่อน" migrate =========
# marker = "รอบนี้แตะ schema (มี backup)" — job revert-db ใน workflow อ่านเพื่อรู้ว่าต้อง restore
#   • เก็บ path backup ตัวเป๊ะของรอบนี้ → revert0 restore จากตัวนี้
#   • เขียนก่อน migrate → migrate พังก็ยังมี marker → revert-db restore ได้
if [ -d "$(dirname "$MARKER")" ]; then
  printf '%s\n' "$BACKUP_FILE" > "$MARKER"
  echo "🔖 marker: $MARKER (backup=$BACKUP_FILE)"
else
  echo "⚠️ ไม่พบ snapshot latest — ไม่ได้เขียน marker (revert-db จะไม่ restore อัตโนมัติ)"
fi

# ========= 5. run migration =========
# NOTE: step นี้ "ไม่ revert เอง" — พังแล้ว exit 1 → job 'revert-db' ใน workflow จัดการ restore
echo "🚀 migration:run..."
if docker run --rm \
     --network dormi_network \
     --env-file "$BE_DIR/$COMPOSE_DIR/$ENV_FILE" \
     -e NODE_ENV=production -e DATABASE_HOST=postgres -e DATABASE_PORT=5432 \
     "$MIGRATE_IMAGE" npm run migration:run; then
  docker rmi "$MIGRATE_IMAGE" >/dev/null 2>&1 || true
  echo "========================"
  echo " ✅ MIGRATION สำเร็จ"
  echo " STATUS: SUCCESS"
  echo "========================"
  exit 0
else
  docker rmi "$MIGRATE_IMAGE" >/dev/null 2>&1 || true
  echo "========================"
  echo " ❌ MIGRATION พัง — exit 1"
  echo "    → job 'revert-db' ใน workflow จะ restore ให้ (revert0 อ่าน marker + backup)"
  echo " STATUS: MIGRATION FAILED"
  echo "========================"
  exit 1
fi
