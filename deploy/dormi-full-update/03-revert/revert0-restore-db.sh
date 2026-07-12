#!/bin/bash
# 03-revert/revert0-restore-db.sh — restore DB จาก backup แบบ "ไม่ drop ของเก่า"
# ------------------------------------------------------------------
# วิธี: เปลี่ยนชื่อ database เก่าเก็บไว้ (ไม่ลบ) → สร้าง database ใหม่ → restore ลงตัวใหม่
#   → ของเก่าที่พัง/ครึ่งๆ ยังอยู่ครบ (ชื่อ <db>_failed_<ts>) กู้มือได้ถ้า restore ก็ยังพลาด
#
# ทำไม rename "database" ไม่ใช่ "schema public":
#   rename schema public ทำ extension (uuid-ossp) หลุด search_path → ตารางที่ใช้
#   uuid_generate_v4() พังตอน restore. rename database ได้เป้าหมายเดียวกันแต่ปลอดภัยกับ extension
#
# ใช้:  bash revert0-restore-db.sh [backup-file]
#       ไม่ใส่ arg → อ่าน backup จาก marker MIGRATION_RAN (ตัวเป๊ะของรอบนี้)
#
# ★ ตัดสินใจเองว่าจะ restore มั้ย ผ่าน marker:
#   - ไม่มี marker = รอบนี้ไม่มี migration → schema ไม่เปลี่ยน → ข้าม (exit 0)
#   - มี marker    = มี migration (schema เปลี่ยน) → restore จาก backup ที่ marker ชี้
set -uo pipefail

PG_CONTAINER="dormi_postgres"
BACKUP_DIR="/root/dormi-releases/db-backups"
MARKER="/root/dormi-releases/snapshots/latest/MIGRATION_RAN"

echo "========================"
echo " Revert — restore DB (rename เก่าเก็บไว้ ไม่ drop)"
echo "========================"

# ========= gate: ไม่มี migration รอบนี้ → ไม่ต้อง restore =========
if [ ! -f "$MARKER" ]; then
  echo "ℹ️ ไม่มี marker MIGRATION_RAN (รอบนี้ไม่มี migration) → schema ไม่เปลี่ยน"
  echo "   ข้าม restore DB (ไม่แตะฐานข้อมูล)"
  echo " STATUS: SKIP"
  exit 0
fi

# ========= หา backup (arg > marker) =========
BACKUP_FILE="${1:-$(cat "$MARKER" 2>/dev/null || true)}"
if [ -z "$BACKUP_FILE" ] || [ ! -s "$BACKUP_FILE" ]; then
  echo "❌ ไม่พบไฟล์ backup (${BACKUP_FILE:-<ว่าง>}) ทั้งจาก arg และ marker"
  echo " STATUS: FAILED"
  exit 1
fi
echo "📄 backup (จาก marker): $BACKUP_FILE"

# ========= เช็ค postgres + อ่านชื่อ user/db =========
if ! docker ps --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$"; then
  echo "❌ ไม่พบ container $PG_CONTAINER"; echo " STATUS: FAILED"; exit 1
fi
DB_USER="$(docker exec "$PG_CONTAINER" printenv POSTGRES_USER)"
DB_NAME="$(docker exec "$PG_CONTAINER" printenv POSTGRES_DB)"
FAILED_DB="${DB_NAME}_failed_$(date +%Y%m%d_%H%M%S)"
echo "🎯 db=$DB_NAME  →  เก็บของเก่าเป็น: $FAILED_DB"

# ========= 1. block connection + terminate + rename เก่า + สร้างใหม่ =========
# ต่อผ่าน db 'postgres' (rename ตัวเองไม่ได้); ON_ERROR_STOP กันทำครึ่งๆ
if ! docker exec -i "$PG_CONTAINER" psql -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 <<SQL
-- กันไม่ให้ app reconnect กลับมาแทรกระหว่าง rename
UPDATE pg_database SET datallowconn = false WHERE datname = '$DB_NAME';
-- ตัด connection เดิมทั้งหมด (rename database ต้องไม่มีใครต่ออยู่)
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
  WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();
-- เก็บเก่าไว้ (ไม่ drop) แล้วสร้างใหม่ว่างเปล่า
ALTER DATABASE "$DB_NAME" RENAME TO "$FAILED_DB";
CREATE DATABASE "$DB_NAME" OWNER "$DB_USER";
SQL
then
  echo "❌ rename/create database ล้มเหลว"
  echo "   ตรวจว่ามี $DB_NAME หรือ $FAILED_DB (docker exec $PG_CONTAINER psql -U $DB_USER -d postgres -c '\\l')"
  echo "   ถ้า $DB_NAME หายไป → กู้: ALTER DATABASE \"$FAILED_DB\" RENAME TO \"$DB_NAME\"; + UPDATE pg_database SET datallowconn=true ..."
  echo " STATUS: FAILED"
  exit 1
fi
echo "✅ rename เก่า + สร้าง $DB_NAME ใหม่ (ว่าง) สำเร็จ"

# ========= 2. restore backup ลง DB ใหม่ =========
echo "📦 restore เข้า $DB_NAME ..."
if docker exec -i "$PG_CONTAINER" pg_restore -U "$DB_USER" -d "$DB_NAME" --no-owner < "$BACKUP_FILE"; then
  echo "========================"
  echo " ✅ RESTORE สำเร็จ"
  echo " db ปัจจุบัน    : $DB_NAME (คืนจาก backup แล้ว)"
  echo " ของเก่าเก็บไว้ : $FAILED_DB (ยังไม่ถูกลบ — ตรวจ/กู้ได้)"
  echo "   ล้างของเก่าเมื่อมั่นใจ: docker exec $PG_CONTAINER psql -U $DB_USER -d postgres -c 'DROP DATABASE \"$FAILED_DB\";'"
  echo " STATUS: SUCCESS"
  echo "========================"
  exit 0
else
  echo "========================"
  echo " ❌ RESTORE ล้มเหลว — $DB_NAME ใหม่อาจไม่สมบูรณ์"
  echo " ★ ของเก่ายังอยู่ครบที่ $FAILED_DB — กู้กลับมือ:"
  echo "   docker exec $PG_CONTAINER psql -U $DB_USER -d postgres -c \\"
  echo "     'DROP DATABASE \"$DB_NAME\"; ALTER DATABASE \"$FAILED_DB\" RENAME TO \"$DB_NAME\"; UPDATE pg_database SET datallowconn=true WHERE datname='\"'\"'$DB_NAME'\"'\"';'"
  echo " STATUS: FAILED (ของเก่าปลอดภัย)"
  echo "========================"
  exit 1
fi
