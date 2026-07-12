#!/bin/bash
# Deploy dormi-backend-2 — อ้างอิง README ของ repo dormi-backend-V2
# รันบน server: cd /root/dormi-edge/deploy/dormi-backend && bash deploy.sh
#
# ก่อนรันครั้งแรก (ทำมือครั้งเดียว — ดู README):
#   - clone https://github.com/Krittater/dormi-backend-2.git → /root/dormi-backend-2
#   - scp docker/.env และ docker/.env.production ขึ้น server
#   - docker network create dormi_network
#
# migration guard: ถ้า commit ที่ pull มา "มีไฟล์ migration เพิ่มใหม่" → backup DB
#   → รัน migration ก่อน (พังก็หยุด ไม่แตะ app เดิม) → ผ่านค่อย deploy
#   ถ้าไม่มี migration ใหม่ → deploy ปกติ (ข้าม backup + migrate)

set -e

APP_NAME="dormi-backend-2"
APP_DIR="/root/$APP_NAME"
GIT_BRANCH="master"
COMPOSE_DIR="docker"
ENV_FILE=".env.production"
COMPOSE="docker compose --env-file $ENV_FILE -f docker-compose.yml -f docker-compose.prod.yml"

# migration / backup config
MIGRATION_DIR="src/database/migrations"
BACKUP_DIR="/root/db-backups"
BACKUP_KEEP=7
MIGRATE_IMAGE="dormi-migrate:latest"

echo "========================"
echo " Deploy: $APP_NAME"
echo "========================"

if [ ! -d "$APP_DIR" ]; then
    echo "❌ ไม่พบ $APP_DIR — clone ก่อน: git clone https://github.com/Krittater/dormi-backend-2.git"
    exit 1
fi

if [ ! -f "$APP_DIR/$COMPOSE_DIR/$ENV_FILE" ]; then
    echo "❌ ไม่พบ $APP_DIR/$COMPOSE_DIR/$ENV_FILE"
    echo "   scp ไฟล์ secret จากเครื่องเราก่อน (ดู README § ส่งไฟล์ secret ขึ้น server)"
    exit 1
fi

# network กลาง — ทุก service ของ dormi ใช้ร่วมกัน (README § สร้าง network กลาง)
docker network create dormi_network 2>/dev/null || true

cd "$APP_DIR"

# =========================
# 🧠 0. เก็บ commit ปัจจุบัน
# =========================
OLD_COMMIT=$(git rev-parse HEAD)
echo "📌 OLD COMMIT (ก่อน deploy): $OLD_COMMIT"

# =========================
# 1. pull latest (README § clone/pull)
# =========================
echo "Pull latest code..."

git fetch origin "$GIT_BRANCH"
git checkout "$GIT_BRANCH"
git reset --hard "origin/$GIT_BRANCH"

NEW_COMMIT=$(git rev-parse HEAD)
echo "📌 NEW COMMIT (หลัง pull): $NEW_COMMIT"

# =========================
# 1.5 ตรวจ migration ใหม่ (เทียบ commit เก่าบน server กับที่เพิ่ง pull)
#     --diff-filter=A = เฉพาะไฟล์ "เพิ่มใหม่" (ตรงกฎ: ห้ามแก้ของเก่า สร้างใหม่เสมอ)
# =========================
NEW_MIGRATIONS=$(git diff --name-only --diff-filter=A "$OLD_COMMIT" "$NEW_COMMIT" \
    -- "$MIGRATION_DIR" | grep -E '\.ts$' || true)

RUN_MIGRATION=false
BACKUP_FILE=""
if [ -n "$NEW_MIGRATIONS" ]; then
    if docker ps --format '{{.Names}}' | grep -q '^dormi_postgres$'; then
        RUN_MIGRATION=true
    else
        echo "⚠️ พบ migration ใหม่ แต่ยังไม่มี dormi_postgres (น่าจะ deploy ครั้งแรก)"
        echo "   → ข้าม explicit migrate, ให้ scheduler จัดการตอน boot"
    fi
else
    echo "✅ ไม่มี migration ใหม่ — deploy ปกติ (ข้าม backup + migrate)"
fi

# =========================
# 1.6 มี migration ใหม่ → backup DB → รัน migration ก่อน deploy
# =========================
if [ "$RUN_MIGRATION" = true ]; then
    echo "========================"
    echo "🔄 พบ migration ใหม่:"
    echo "$NEW_MIGRATIONS"
    echo "========================"

    # --- 2a. Backup (ใช้ env ในตัว container เอง ไม่ต้องรู้ค่า creds) ---
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/dormi_v2-$(date +%Y%m%d-%H%M%S).dump"
    echo "📦 Backup DB → $BACKUP_FILE"
    # ห่อด้วย if ! กัน set -e ตัดก่อน handler (ถ้า pg_dump พังต้อง reset git ให้เรียบร้อย)
    if ! docker exec dormi_postgres sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$BACKUP_FILE"; then
        echo "❌ pg_dump ล้มเหลว — ยกเลิก deploy เพื่อความปลอดภัย (ไม่ migrate)"
        rm -f "$BACKUP_FILE"
        git reset --hard "$OLD_COMMIT"
        exit 1
    fi

    if [ ! -s "$BACKUP_FILE" ]; then
        echo "❌ Backup ว่างเปล่า — ยกเลิก deploy เพื่อความปลอดภัย (ไม่ migrate)"
        rm -f "$BACKUP_FILE"
        git reset --hard "$OLD_COMMIT"
        exit 1
    fi
    echo "✅ Backup สำเร็จ ($(du -h "$BACKUP_FILE" | cut -f1))"

    # rotate — เก็บแค่ BACKUP_KEEP ไฟล์ล่าสุด ที่เหลือลบทิ้ง
    ls -1t "$BACKUP_DIR"/dormi_v2-*.dump 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f

    # --- 2b. build migration runner จาก build stage (มี ts-node + src ครบ) ---
    #   runtime image รัน migration ไม่ได้ (npm ci --omit=dev + copy แค่ dist/)
    echo "🏗️  Build migration runner (build stage)..."
    # ถ้า code ใหม่ compile ไม่ผ่าน → build พัง → ต้อง reset git ก่อน exit (กัน set -e ตัด)
    if ! docker build --target build -t "$MIGRATE_IMAGE" "$APP_DIR"; then
        echo "❌ Build migration runner ล้มเหลว (code ใหม่ compile ไม่ผ่าน?) — ยกเลิก deploy"
        git reset --hard "$OLD_COMMIT"
        exit 1
    fi

    # --- 2c. run migration (TypeORM ห่อ transaction — พังแล้ว rollback DB อัตโนมัติ) ---
    echo "🚀 Run migration:run..."
    if ! docker run --rm \
            --network dormi_network \
            --env-file "$APP_DIR/$COMPOSE_DIR/$ENV_FILE" \
            -e NODE_ENV=production \
            -e DATABASE_HOST=postgres \
            -e DATABASE_PORT=5432 \
            "$MIGRATE_IMAGE" \
            npm run migration:run; then
        echo "========================"
        echo "❌ MIGRATION FAILED"
        echo "   TypeORM rollback DB ให้แล้ว (transaction) — DB ไม่ค้างครึ่งทาง"
        echo "   Backup อยู่ที่: $BACKUP_FILE"
        echo "↩️ คืน code เป็น commit เดิม (containers เดิมยังรันของเก่าอยู่ ใช้งานได้ปกติ)"
        echo "========================"
        git reset --hard "$OLD_COMMIT"
        docker rmi "$MIGRATE_IMAGE" 2>/dev/null || true
        exit 1
    fi

    docker rmi "$MIGRATE_IMAGE" 2>/dev/null || true
    echo "✅ Migration สำเร็จ"
fi

# =========================
# 2. build + restart (README § build + รันทั้ง stack)
# =========================
echo "Build and restart containers..."

# ส่ง commit ที่ deploy เข้า container → โผล่ที่ GET /version (compose อ่าน ${APP_VERSION})
export APP_VERSION="$(git -C "$APP_DIR" rev-parse --short HEAD)"
echo "🔖 APP_VERSION=$APP_VERSION"

cd "$APP_DIR/$COMPOSE_DIR"
$COMPOSE up -d --build

docker image prune -f

# =========================
# 3. check status
# =========================
echo "Checking compose status..."

FAILED=$($COMPOSE ps --services --filter "status=exited")

if [ ! -z "$FAILED" ]; then
    echo "❌ DEPLOY FAILED"

    echo "❌ Failed services:"
    echo "$FAILED"

    echo "🔁 Rolling back..."

    echo "↩️ Rollback FROM: $NEW_COMMIT"
    echo "↩️ Rollback TO:   $OLD_COMMIT"

    if [ "$RUN_MIGRATION" = true ]; then
        echo "⚠️ หมายเหตุ: รอบนี้ migrate DB ไปแล้ว → schema จะ 'ล้ำหน้า' code เก่าที่กำลัง rollback"
        echo "   - migration แบบ additive (เพิ่ม column/table) → code เก่ามักยังทำงานได้"
        echo "   - migration แบบ destructive (ลบ/แก้ column) → อาจต้อง restore DB จาก backup:"
        echo "     docker exec -i dormi_postgres pg_restore -U dormi -d dormi_v2 --clean --if-exists < $BACKUP_FILE"
    fi

    git -C "$APP_DIR" reset --hard "$OLD_COMMIT"

    # /version สะท้อน commit เก่าที่ rollback กลับมา (ไม่ใช่ commit ใหม่ที่พัง)
    export APP_VERSION="$(git -C "$APP_DIR" rev-parse --short HEAD)"

    $COMPOSE up -d --build --force-recreate

    echo "========================"
    echo " ROLLBACK DONE"
    echo " Current commit: $OLD_COMMIT"
    echo "========================"

    exit 1
fi

# =========================
# 4. ตรวจหลัง deploy (README § ตรวจว่าขึ้นครบ)
# =========================
echo "Post-deploy checks..."

docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "dormi_postgres|dormi-api|dormi-scheduler" || true

if ! docker ps --format '{{.Names}}' | grep -q '^dormi_postgres$'; then
    echo "⚠️ ไม่พบ dormi_postgres"
elif ! docker inspect dormi_postgres --format '{{.State.Health.Status}}' 2>/dev/null | grep -q healthy; then
    echo "⚠️ dormi_postgres ยังไม่ healthy — รอสักครู่แล้ว docker ps อีกครั้ง"
fi

echo "========================"
echo " DEPLOY SUCCESS"
echo " OLD COMMIT : $OLD_COMMIT"
echo " NEW COMMIT : $NEW_COMMIT"
echo " MIGRATION  : $([ "$RUN_MIGRATION" = true ] && echo "รัน (backup: $BACKUP_FILE)" || echo 'ไม่มี migration ใหม่')"
echo " STATUS     : OK"
echo " ถัดไป     : deploy edge แล้วทดสอบ https://dormi-api.dormi-linkandrent.com"
echo "========================"
