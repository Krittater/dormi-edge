#!/bin/bash
# 00-prepare/backup.sh — backup ฐานข้อมูล "ทั้งก้อน" (schema + data ทั้งหมด)
# ------------------------------------------------------------------
# เน้นความรัดกุม: ไฟล์ต้องไม่พัง + restore ได้อย่างมั่นใจ + ขนาดไม่บวม
#   - custom format (-Fc)  : บีบอัดในตัว ~5-10 เท่า (ไม่ต้องต่อ gzip = ไม่มีกับดัก pipefail)
#   - เขียน .part → ตรวจ → rename : ไฟล์ครึ่งๆ จะไม่มีวันมีชื่อจริง (atomic)
#   - verify ด้วย pg_restore -l  : พิสูจน์ว่าอ่านกลับได้จริงก่อนถือว่าสำเร็จ
#   - ชื่อไฟล์ = yyyy-mm-dd-HHMMSS ณ เวลาที่ backup (เรียงตามเวลาได้)
#
# รันบน server:  bash backup.sh
# ต้องมี: container dormi_postgres รันอยู่

set -euo pipefail

# ========= config =========
PG_CONTAINER="dormi_postgres"
BACKUP_DIR="/root/dormi-releases/db-backups"
KEEP=20                              # เก็บ backup ล่าสุดกี่ไฟล์

TS="$(date +%Y-%m-%d-%H%M%S)"        # yyyy-mm-dd-timestamp ณ เวลานี้
BACKUP_FILE="$BACKUP_DIR/${TS}.dump" # .dump = custom format (บีบอัดในตัว)
TMP_FILE="${BACKUP_FILE}.part"       # เขียนที่นี่ก่อน สำเร็จค่อย rename

echo "========================"
echo " Backup DB ทั้งก้อน (schema + data)"
echo " เวลา: $TS"
echo "========================"

# postgres ต้องรันอยู่
if ! docker ps --format '{{.Names}}' | grep -q "^${PG_CONTAINER}$"; then
  echo "❌ ไม่พบ container $PG_CONTAINER (postgres ต้องรันอยู่)"
  exit 1
fi

mkdir -p "$BACKUP_DIR"

# อ่านชื่อ user/db จาก container ครั้งเดียว → ใช้ทั้ง dump และข้อความ restore ให้ "ตรงกันเสมอ"
DB_USER="$(docker exec "$PG_CONTAINER" printenv POSTGRES_USER)"
DB_NAME="$(docker exec "$PG_CONTAINER" printenv POSTGRES_DB)"
echo "🎯 target: user=$DB_USER db=$DB_NAME"

# ========= dump ทั้ง database (custom format, บีบอัดในตัว) =========
#   -Fc        : custom format — บีบอัด + ตรวจสอบได้ + restore เลือกได้
#   --no-owner : ไม่ผูก owner → restore ข้ามเครื่อง/ข้าม user ได้
#   (custom format ใส่ --clean ตอน "restore" ไม่ใช่ตอน dump)
echo "📦 กำลัง dump → $BACKUP_FILE"
if ! docker exec "$PG_CONTAINER" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc --no-owner > "$TMP_FILE"; then
  echo "❌ pg_dump ล้มเหลว — ลบไฟล์ที่ค้าง"
  rm -f "$TMP_FILE"
  exit 1
fi

# กันไฟล์ว่าง (dump ไม่สำเร็จจริง)
if [ ! -s "$TMP_FILE" ]; then
  echo "❌ ไฟล์ backup ว่างเปล่า — ยกเลิก"
  rm -f "$TMP_FILE"
  exit 1
fi

# ========= verify — พิสูจน์ว่า "อ่านกลับได้จริง" ก่อนถือว่าใช้ได้ =========
# pg_restore -l อ่าน TOC ของ archive; ถ้าอ่านไม่ได้ = ไฟล์เสีย → ห้ามเก็บ
echo "🔍 ตรวจความสมบูรณ์ (pg_restore -l)..."
if ! docker exec -i "$PG_CONTAINER" pg_restore -l > /dev/null 2>&1 < "$TMP_FILE"; then
  echo "❌ backup เสียหาย (pg_restore -l อ่านไม่ได้) — ทิ้งไฟล์"
  rm -f "$TMP_FILE"
  exit 1
fi

# ผ่านทุกด่าน → rename เป็นชื่อจริง (atomic บน filesystem เดียวกัน)
mv "$TMP_FILE" "$BACKUP_FILE"
SIZE="$(du -h "$BACKUP_FILE" | cut -f1)"

# ========= rotate — เก็บแค่ KEEP ไฟล์ล่าสุด =========
{ ls -1t "$BACKUP_DIR"/*.dump 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f; } || true

echo "========================"
echo " ✅ BACKUP สำเร็จ + ตรวจแล้วว่าอ่านกลับได้"
echo " ไฟล์  : $BACKUP_FILE"
echo " ขนาด  : $SIZE"
echo "------------------------"
echo " restore ทั้งก้อน:"
echo "   docker exec -i $PG_CONTAINER pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists --no-owner < $BACKUP_FILE"
echo " ⚠️  --clean = DROP ของเดิมทิ้งก่อนแล้วสร้างใหม่ (เขียนทับทั้งก้อน ไม่ใช่ merge!)"
echo " ดู schema อย่างเดียว (ไม่ต้อง restore):"
echo "   pg_restore --schema-only $BACKUP_FILE"
echo "========================"
