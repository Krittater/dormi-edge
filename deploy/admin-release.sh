#!/usr/bin/env bash
# Deploy the reviewed Admin API (marketing agent village); Landing is released separately on Vercel.
#   inspect      read-only preflight
#   deploy       backup → build → migrate → swap → verify → reload edge (autopilot stays OFF)
#   autopilot-on remove MARKETING_AUTOPILOT=off after the village was tested on prod
set -Eeuo pipefail
umask 077
MODE=${1:-inspect}
[[ "$MODE" == inspect || "$MODE" == deploy || "$MODE" == autopilot-on ]] || exit 2
AD=/root/dormi-admin
AD_SHA=__SET_AFTER_ADMIN_MERGE__
HOST=admin-api.dormi-linkandrent.com
. /root/dormi-edge/deploy/lib/deploy-lock.sh
deploy_lock "admin release $MODE"
sql() { docker exec -i dormi_postgres sh -c 'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d dormi_admin'; }
sql_val() { docker exec dormi_postgres sh -c 'exec psql -X -tA -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d dormi_admin -c "$1"' sh "$1"; }
health() { curl -fsS --max-time 15 --resolve "$HOST:443:127.0.0.1" "https://$HOST/$1"; }
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 15 --resolve "$HOST:443:127.0.0.1" "https://$HOST/$1"; }
admin_env() { docker exec docker-dormi-admin-1 node -p "process.env.$1 || ''"; }
ad_compose() { (cd "$AD/docker"; docker compose --env-file ../.env.production -f docker-compose.yml -f docker-compose.prod.yml -f "$1" "${@:2}"); }
# งานที่ agent กำลังทำ — redeploy ตัดกลางคันแล้วต้องทำใหม่ (เสียค่า AI ซ้ำ)
running_tasks() {
  [[ "$(sql_val "SELECT to_regclass('public.marketing_agent_tasks') IS NOT NULL")" == t ]] || { echo 0; return; }
  sql_val "SELECT count(*) FROM marketing_agent_tasks WHERE status = 'running'"
}
# ตั้งหรือลบ (value ว่าง) key เดียวใน .env.production — บรรทัดอื่นไม่แตะ
set_env() {
  python3 - "$AD/.env.production" "$1" "${2-}" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); key, value = sys.argv[2], sys.argv[3]
lines=[s for s in p.read_text().splitlines() if not re.match(rf'^\s*{key}\s*=',s)]
if value: lines.append(f"{key}={value}")
p.write_text("\n".join(lines)+"\n")
PY
}
wait_healthy() {
  for attempt in $(seq 1 30); do
    [[ "$(docker inspect --format '{{.State.Health.Status}}' docker-dormi-admin-1 2>/dev/null || true)" == healthy ]] && return 0
    sleep 3
  done
  return 1
}

echo "=== PREFLIGHT $MODE $(date -Is) ==="
docker ps --format '{{.Names}} | {{.Status}} | {{.Image}}'
df -h /var/lib/docker
test -d "$AD/.git"
test -z "$(git -C "$AD" status --porcelain --untracked-files=no)" || { echo "Tracked changes: $AD; stop"; exit 1; }
git -C "$AD" log -1 --format='%h %s'
health health
health api/.well-known/jwks.json >/dev/null
docker exec -i docker-dormi-admin-1 node - <<'JS'
const e=process.env; const db=e.DATABASE_URL ? new URL(e.DATABASE_URL).pathname.slice(1) : e.DATABASE_NAME;
if(db!=="dormi_admin") throw Error("Unexpected runtime database");
console.log(JSON.stringify({database:db,version:e.APP_VERSION,aiKey:!!e.ANTHROPIC_API_KEY,autopilot:e.MARKETING_AUTOPILOT||"(default)"}));
JS
sql <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout='15s';
SELECT name FROM migrations ORDER BY id;
COMMIT;
SQL
echo "running_agent_tasks=$(running_tasks)"
docker exec dormi-edge nginx -t
[[ "$MODE" == inspect ]] && { echo INSPECTION_COMPLETE; exit 0; }
command -v python3 >/dev/null
test "$(running_tasks)" = 0 || { echo "Agent tasks are running; wait until GET /api/marketing/agents/tasks?scope=active is empty"; exit 1; }
TS=$(date -u +%Y%m%dT%H%M%SZ)
SNAP=/root/dormi-releases/admin-$MODE-$TS
mkdir -m 700 "$SNAP"
cp -p "$AD/.env.production" "$SNAP/admin.env"
chmod 600 "$SNAP/admin.env"
AD_OLD=$(docker inspect --format '{{.Image}}' docker-dormi-admin-1)
AD_VER=$(admin_env APP_VERSION)
printf 'services:\n  dormi-admin:\n    image: %s\n' "$AD_OLD" > "$SNAP/admin-old.yml"
PHASE=none
rollback() {
  rc=$?; trap - ERR; set +e
  echo "DEPLOY_FAILED mode=$MODE phase=$PHASE backup=$SNAP"
  if [[ "$PHASE" == admin ]]; then
    cp -p "$SNAP/admin.env" "$AD/.env.production"
    export APP_VERSION="$AD_VER"
    ad_compose "$SNAP/admin-old.yml" up -d --no-build --no-deps dormi-admin
    wait_healthy && health health
  fi
  echo "No automatic DB restore: preserve writes; migrations are additive and transactional."
  exit "$rc"
}

if [[ "$MODE" == autopilot-on ]]; then
  # image เดิม แค่เอา MARKETING_AUTOPILOT=off ออกแล้วสร้าง container ใหม่ให้อ่าน env
  trap rollback ERR
  PHASE=admin
  set_env MARKETING_AUTOPILOT ""
  export APP_VERSION="$AD_VER"
  ad_compose "$SNAP/admin-old.yml" up -d --no-build --no-deps --force-recreate dormi-admin
  wait_healthy
  health health
  test -z "$(admin_env MARKETING_AUTOPILOT)"
  PHASE=none
  trap - ERR
  echo "AUTOPILOT_ON backup=$SNAP (weekly chain Monday 07:00, summary 09:00 Bangkok; catches up this week if no run yet)"
  exit 0
fi

test "$(df -Pk /var/lib/docker | awk 'NR==2 {print $4}')" -gt 8388608 || { echo "Need at least 8 GiB free"; exit 1; }
git -C "$AD" fetch git@github.com:Krittater/dormi-admin.git master:refs/remotes/origin/master
test "$(git -C "$AD" rev-parse origin/master)" = "$AD_SHA" || { echo "Remote target changed; stop for review"; exit 1; }
git -C "$AD" merge-base --is-ancestor HEAD "$AD_SHA"
docker tag "$AD_OLD" "dormi-admin:before-agent-$TS"
printf '%s\n' "admin=$AD_OLD" "admin_version=$AD_VER" > "$SNAP/images.txt"
docker exec dormi_postgres sh -c 'exec pg_dump -U "$POSTGRES_USER" -Fc dormi_admin' > "$SNAP/dormi_admin.dump"
test -s "$SNAP/dormi_admin.dump"
docker exec -i dormi_postgres pg_restore --list < "$SNAP/dormi_admin.dump" > "$SNAP/dormi_admin.toc"
docker exec -i dormi_postgres pg_restore --file=/dev/null < "$SNAP/dormi_admin.dump"
sha256sum "$SNAP/dormi_admin.dump"
echo "BACKUPS_VERIFIED=$SNAP"
git -C "$AD" merge --ff-only "$AD_SHA"
# Build only tracked source; do not include server-local secrets.
mkdir "$SNAP/admin-source"
git -C "$AD" archive "$AD_SHA" | tar -x -C "$SNAP/admin-source"
test ! -f "$SNAP/admin-source/.env.production"
docker build -t "dormi-admin:release-${AD_SHA:0:7}" "$SNAP/admin-source"
printf 'services:\n  dormi-admin:\n    image: dormi-admin:release-%s\n' "${AD_SHA:0:7}" > "$SNAP/admin-new.yml"
trap rollback ERR
PHASE=admin
# รอบแรกปิด autopilot ไว้: มี API key แล้วระบบจะไล่ทำรอบสัปดาห์ที่ข้ามไปทันทีหลังบูต
set_env MARKETING_AUTOPILOT off
export APP_VERSION=${AD_SHA:0:7}
# TypeORM only: no seed, both agent migrations in one transaction.
ad_compose "$SNAP/admin-new.yml" run --rm --no-deps dormi-admin npm run migration:run:prod -- --transaction all
sql <<'SQL'
DO $$ BEGIN
IF (SELECT count(*) FROM migrations WHERE name IN ('AddMarketingAgentEvents1790300000000','AddAgentVillage1790400000000')) <> 2 THEN RAISE EXCEPTION 'Missing migrations'; END IF;
IF to_regclass('public.marketing_agent_tasks') IS NULL OR to_regclass('public.marketing_ai_usage') IS NULL THEN RAISE EXCEPTION 'Missing schema'; END IF;
END $$;
SQL
ad_compose "$SNAP/admin-new.yml" up -d --no-build --no-deps dormi-admin
wait_healthy
health health
health api/.well-known/jwks.json >/dev/null
test "$(admin_env APP_VERSION)" = "${AD_SHA:0:7}"
test "$(admin_env MARKETING_AUTOPILOT)" = off
# route ใหม่ต้องมีและยังบังคับ auth (404 = ยังเป็นโค้ดเก่า)
test "$(code api/marketing/agents/status)" = 401
PHASE=none
trap - ERR
# edge: /api/marketing/ รอได้ 180 วิ (config มากับ commit นี้แล้ว ตรวจผ่านตอน preflight)
docker exec dormi-edge nginx -t
docker exec dormi-edge nginx -s reload
sleep 2
test "$(code api/marketing/agents/status)" = 401
echo "API_RELEASE_COMPLETE admin=$AD_SHA backup=$SNAP (autopilot OFF — run autopilot-on after testing)"
docker ps --format '{{.Names}} | {{.Status}} | {{.Image}}'
