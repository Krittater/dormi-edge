#!/usr/bin/env bash
# Deploy reviewed Admin APIs; Landing is released separately on Vercel.
set -Eeuo pipefail
umask 077
MODE=${1:-inspect}
[[ "$MODE" == inspect || "$MODE" == deploy ]] || exit 2
BE=/root/dormi-backend-2
AD=/root/dormi-admin
BE_SHA=280ed57deb738667196f8633f467ceb973e234aa
AD_SHA=e4494cc05768174c12a95c9e3b78c15972e66dfe
. /root/dormi-edge/deploy/lib/deploy-lock.sh
deploy_lock "admin release $MODE"
sql() { docker exec -i dormi_postgres sh -c 'exec psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$1"' sh "$1"; }
health() { curl -fsS --max-time 15 --resolve "$1:443:127.0.0.1" "https://$1/$2"; }
echo "=== PREFLIGHT $(date -Is) ==="
docker ps --format '{{.Names}} | {{.Status}}'
df -h /var/lib/docker
for repo in "$BE" "$AD"; do
  test -d "$repo/.git"
  test -z "$(git -C "$repo" status --porcelain --untracked-files=no)" || { echo "Tracked changes: $repo; stop"; exit 1; }
  git -C "$repo" log -1 --format='%h %s'
done
health dormi-api.dormi-linkandrent.com version
health admin-api.dormi-linkandrent.com health
health admin-api.dormi-linkandrent.com api/.well-known/jwks.json >/dev/null
for pair in docker-dormi-api-1:dormi_v2 docker-dormi-admin-1:dormi_admin; do
  cid=${pair%%:*}; db=${pair#*:}
  docker exec -i "$cid" node - "$db" <<'JS'
const e=process.env; let db=e.DATABASE_NAME;
if(e.DATABASE_URL) db=new URL(e.DATABASE_URL).pathname.slice(1);
if(db!==process.argv[2]) throw Error("Unexpected runtime database");
console.log(JSON.stringify({database:db,version:e.APP_VERSION,jwtExpiry:e.JWT_EXPIRES_IN,resendConfigured:!!e.RESEND_API_KEY,mailFromValid:/^(?:[^<>]+<[^<>\s]+@[^<>\s]+>|[^<>\s]+@[^<>\s]+)$/.test(e.MAIL_FROM||"")}));
JS
done
sql dormi_admin <<'SQL'
BEGIN READ ONLY;
SET LOCAL statement_timeout='15s';
SELECT name FROM migrations ORDER BY id;
SELECT count(*) AS duplicate_email_groups FROM (SELECT email FROM registrations WHERE email IS NOT NULL GROUP BY email HAVING count(*)>1) d;
COMMIT;
SQL
[[ "$MODE" == deploy ]] || { echo INSPECTION_COMPLETE; exit 0; }
test "$(df -Pk /var/lib/docker | awk 'NR==2 {print $4}')" -gt 8388608 || { echo "Need at least 8 GiB free"; exit 1; }
command -v python3 >/dev/null
for pair in "$BE:$BE_SHA" "$AD:$AD_SHA"; do
  repo=${pair%%:*}; sha=${pair#*:}
  git -C "$repo" fetch origin master
  test "$(git -C "$repo" rev-parse origin/master)" = "$sha" || { echo "Remote target changed; stop for review"; exit 1; }
  git -C "$repo" merge-base --is-ancestor HEAD "$sha"
done
# No backend migrations were introduced in this reviewed release.
test -z "$(git -C "$BE" diff --name-only HEAD "$BE_SHA" -- src/database/migrations)" || { echo "Backend schema change requires separate review"; exit 1; }
TS=$(date -u +%Y%m%dT%H%M%SZ)
SNAP=/root/dormi-releases/admin-release-$TS
mkdir -m 700 "$SNAP"
cp -p "$BE/docker/.env.production" "$SNAP/backend.env"
cp -p "$AD/.env.production" "$SNAP/admin.env"
chmod 600 "$SNAP/"*.env
BE_OLD=$(docker inspect --format '{{.Image}}' docker-dormi-api-1)
SCH_OLD=$(docker inspect --format '{{.Image}}' docker-dormi-scheduler-1)
AD_OLD=$(docker inspect --format '{{.Image}}' docker-dormi-admin-1)
BE_VER=$(docker exec docker-dormi-api-1 node -p 'process.env.APP_VERSION || "unknown"')
AD_VER=$(docker exec docker-dormi-admin-1 node -p 'process.env.APP_VERSION || "unknown"')
docker tag "$BE_OLD" "dormi-api:before-admin-$TS"
docker tag "$SCH_OLD" "dormi-scheduler:before-admin-$TS"
docker tag "$AD_OLD" "dormi-admin:before-admin-$TS"
printf '%s\n' "backend=$BE_OLD" "scheduler=$SCH_OLD" "admin=$AD_OLD" "backend_version=$BE_VER" "admin_version=$AD_VER" > "$SNAP/images.txt"
for db in dormi_v2 dormi_admin; do
  docker exec dormi_postgres sh -c 'exec pg_dump -U "$POSTGRES_USER" -Fc "$1"' sh "$db" > "$SNAP/$db.dump"
  test -s "$SNAP/$db.dump"
  docker exec -i dormi_postgres pg_restore --list < "$SNAP/$db.dump" > "$SNAP/$db.toc"
  docker exec -i dormi_postgres pg_restore --file=/dev/null < "$SNAP/$db.dump"
  sha256sum "$SNAP/$db.dump"
done
echo "BACKUPS_VERIFIED=$SNAP"
git -C "$BE" merge --ff-only "$BE_SHA"
git -C "$AD" merge --ff-only "$AD_SHA"
# Build only tracked source; do not include server-local secrets.
mkdir "$SNAP/backend-source" "$SNAP/admin-source"
git -C "$BE" archive "$BE_SHA" | tar -x -C "$SNAP/backend-source"
git -C "$AD" archive "$AD_SHA" | tar -x -C "$SNAP/admin-source"
test ! -f "$SNAP/admin-source/.env.production"
test ! -f "$SNAP/backend-source/docker/.env.production"
docker build -t "dormi-backend:admin-$TS" "$SNAP/backend-source"
docker build -t "dormi-admin:release-$TS" "$SNAP/admin-source"
cat > "$SNAP/backend-new.yml" <<EOF
services:
  dormi-api:
    image: dormi-backend:admin-$TS
  dormi-scheduler:
    image: dormi-backend:admin-$TS
EOF
cat > "$SNAP/backend-old.yml" <<EOF
services:
  dormi-api:
    image: $BE_OLD
  dormi-scheduler:
    image: $SCH_OLD
EOF
printf 'services:\n  dormi-admin:\n    image: dormi-admin:release-%s\n' "$TS" > "$SNAP/admin-new.yml"
printf 'services:\n  dormi-admin:\n    image: %s\n' "$AD_OLD" > "$SNAP/admin-old.yml"
be_compose() { (cd "$BE/docker"; docker compose --env-file .env.production -f docker-compose.yml -f docker-compose.prod.yml -f "$SNAP/backend-$1.yml" "${@:2}"); }
ad_compose() { (cd "$AD/docker"; docker compose --env-file ../.env.production -f docker-compose.yml -f docker-compose.prod.yml -f "$SNAP/admin-$1.yml" "${@:2}"); }
PHASE=none
rollback() {
  rc=$?; trap - ERR; set +e
  echo "DEPLOY_FAILED phase=$PHASE backup=$SNAP"
  if [[ "$PHASE" == backend ]]; then
    cp -p "$SNAP/backend.env" "$BE/docker/.env.production"
    export APP_VERSION="$BE_VER"
    be_compose old up -d --no-build --no-deps dormi-api dormi-scheduler
    health dormi-api.dormi-linkandrent.com version
  elif [[ "$PHASE" == admin ]]; then
    cp -p "$SNAP/admin.env" "$AD/.env.production"
    export APP_VERSION="$AD_VER"
    ad_compose old up -d --no-build --no-deps dormi-admin
    health admin-api.dormi-linkandrent.com health
  fi
  echo "No automatic DB restore: preserve writes; migrations are additive and transactional."
  exit "$rc"
}
trap rollback ERR
# Preserve the sender; repair only the missing-angle-bracket format.
PHASE=backend
python3 - "$BE/docker/.env.production" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); lines=p.read_text().splitlines()
ix=[i for i,s in enumerate(lines) if re.match(r'^\s*MAIL_FROM\s*=',s)]
if len(ix)!=1: raise SystemExit("Expected exactly one MAIL_FROM setting")
i=ix[0]; value=lines[i].split("=",1)[1].strip().strip(chr(34)).strip(chr(39))
if not re.fullmatch(r'(?:[^<>]+<[^<>\s]+@[^<>\s]+>|[^<>\s]+@[^<>\s]+)',value):
    m=re.fullmatch(r'([^<>]+?)\s+([^<>\s]+@[^<>\s]+)',value)
    if not m: raise SystemExit("Unrecognized MAIL_FROM; no guessing")
    value=f"{m[1]} <{m[2]}>"
    lines[i]="MAIL_FROM="+chr(34)+value+chr(34)
    p.write_text("\n".join(lines)+"\n")
print("MAIL_FROM format validated")
PY
export APP_VERSION=${BE_SHA:0:7}
be_compose new up -d --no-build --no-deps dormi-api dormi-scheduler
be_ok=false
for attempt in $(seq 1 30); do
  body=$(health dormi-api.dormi-linkandrent.com version 2>/dev/null || true)
  if [[ "$body" == *'"version":"280ed57"'* ]]; then be_ok=true; break; fi
  sleep 3
done
[[ "$be_ok" == true ]]
test "$(docker exec docker-dormi-scheduler-1 node -p 'process.env.APP_VERSION')" = 280ed57
echo BACKEND_DEPLOY_VERIFIED
PHASE=admin
python3 - "$AD/.env.production" <<'PY'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); lines=p.read_text().splitlines()
ix=[i for i,s in enumerate(lines) if re.match(r'^\s*JWT_EXPIRES_IN\s*=',s)]
if len(ix)>1: raise SystemExit("Duplicate JWT_EXPIRES_IN settings")
if ix: lines[ix[0]]="JWT_EXPIRES_IN=15m"
else: lines.append("JWT_EXPIRES_IN=15m")
p.write_text("\n".join(lines)+"\n")
PY
export APP_VERSION=${AD_SHA:0:7}
# TypeORM only: no seed, and all three changes in one transaction.
ad_compose new run --rm --no-deps dormi-admin npm run migration:run:prod -- --transaction all
sql dormi_admin <<'SQL'
DO $$ BEGIN
IF (SELECT count(*) FROM migrations WHERE name IN ('AddUniqueEmailIndexToRegistrations1789400000000','AddIsActiveToAdminUsers1789500000000','AddAdminRefreshTokens1789600000000')) <> 3 THEN RAISE EXCEPTION 'Missing migrations'; END IF;
IF to_regclass('public.admin_refresh_tokens') IS NULL OR to_regclass('public."UQ_registrations_email"') IS NULL THEN RAISE EXCEPTION 'Missing schema'; END IF;
IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='is_active') THEN RAISE EXCEPTION 'Missing is_active'; END IF;
END $$;
SQL
ad_compose new up -d --no-build --no-deps dormi-admin
ad_ok=false
for attempt in $(seq 1 30); do
  if [[ "$(docker inspect --format '{{.State.Health.Status}}' docker-dormi-admin-1 2>/dev/null || true)" == healthy ]]; then ad_ok=true; break; fi
  sleep 3
done
[[ "$ad_ok" == true ]]
health admin-api.dormi-linkandrent.com health
health admin-api.dormi-linkandrent.com api/.well-known/jwks.json >/dev/null
test "$(docker exec docker-dormi-admin-1 node -p 'process.env.APP_VERSION')" = e4494cc
test "$(docker exec docker-dormi-admin-1 node -p 'process.env.JWT_EXPIRES_IN')" = 15m
PHASE=none
trap - ERR
echo "API_RELEASE_COMPLETE backend=$BE_SHA admin=$AD_SHA backup=$SNAP"
docker ps --format '{{.Names}} | {{.Status}}'
