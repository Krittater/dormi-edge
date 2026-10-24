#!/usr/bin/env bash
# Monitoring (Grafana Alloy → Grafana Cloud) บนเครื่อง dormi
#   inspect   อ่านอย่างเดียว: สถานะ alloy, RAM, key ใน .env (บอกแค่ชื่อ ไม่พิมพ์ค่า), role dormi_monitor
#   setup     สร้าง/หมุนรหัส role dormi_monitor (openssl rand) → เขียน PG_MONITOR_DSN ลง .env (chmod 600)
#             ไม่พิมพ์รหัสผ่านออกจอ · ถ้า alloy รันอยู่จะ recreate ให้ใช้รหัสใหม่
#   up        ตรวจ .env ครบ → สร้างไฟล์ log backup ถ้ายังไม่มี → compose up → รอ healthy
#   down      หยุด alloy (เก็บ volume positions/WAL ไว้) = rollback ของ monitoring ทั้งหมด
# รันบน server: bash /root/dormi-edge/deploy/monitoring/monitoring.sh <mode>
set -Eeuo pipefail
umask 077

MODE=${1:-inspect}
case "$MODE" in
  inspect|setup|up|down) ;;
  *) echo "usage: $0 inspect | setup | up | down" >&2; exit 2 ;;
esac

EDGE_DIR=${EDGE_DIR:-/root/dormi-edge}
MON_DIR="$EDGE_DIR/deploy/monitoring"
COMPOSE_FILE="$MON_DIR/docker-compose.yml"
ENV_FILE="$MON_DIR/.env"
SQL_FILE="$MON_DIR/sql/create-monitor-role.sql"
PROJECT=dormi-monitoring
CONTAINER=dormi-alloy
NETWORK=dormi_network
PG_CONTAINER=${PG_CONTAINER:-dormi_postgres}
BACKUP_LOG=${BACKUP_LOG:-/var/log/dormi-db-backup.log}
REQUIRED_KEYS=(GRAFANA_PROM_URL GRAFANA_PROM_USER GRAFANA_LOKI_URL GRAFANA_LOKI_USER GRAFANA_CLOUD_TOKEN PG_MONITOR_DSN)

# shellcheck source=/dev/null
. "$EDGE_DIR/deploy/lib/deploy-lock.sh"
deploy_lock "monitoring $MODE"

mcompose() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }

# ค่าของ key ใน .env (บรรทัดสุดท้ายที่ตรง) — ใช้ภายในเท่านั้น ห้าม echo ออกจอ
env_value() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | tail -n1; }

# .env ต้องมีและเป็นของ root อ่านได้คนเดียว
ensure_env_file() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$MON_DIR/.env.example" "$ENV_FILE"
    echo "สร้าง $ENV_FILE จาก .env.example แล้ว — เติม GRAFANA_* ก่อน up"
  fi
  chmod 600 "$ENV_FILE"
}

# บอกเฉพาะชื่อ key ที่ยังว่าง (ไม่พิมพ์ค่า) · คืน 1 ถ้ามีที่ว่าง
check_env_keys() {
  local k missing=()
  for k in "${REQUIRED_KEYS[@]}"; do
    [[ -n "$(env_value "$k")" ]] || missing+=("$k")
  done
  if ((${#missing[@]})); then
    echo "ENV_MISSING: ${missing[*]}"
    return 1
  fi
  echo "ENV_OK: ครบ ${#REQUIRED_KEYS[@]} key (ไม่แสดงค่า)"
}

pg_env() { docker exec "$PG_CONTAINER" printenv "$1" 2>/dev/null || true; }

role_state() {
  local u d
  u=$(pg_env POSTGRES_USER); d=$(pg_env POSTGRES_DB)
  docker exec "$PG_CONTAINER" psql -X -At -U "${u:-dormi}" -d "${d:-dormi_v2}" -c \
    "SELECT 'MONITOR_ROLE=' || CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dormi_monitor') THEN 'present' ELSE 'missing' END" \
    2>/dev/null || echo "MONITOR_ROLE=unknown (ต่อ $PG_CONTAINER ไม่ได้)"
}

alloy_state() {
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    docker inspect --format '{{.Name}} | {{.Config.Image}} | {{.State.Status}} | health={{if .State.Health}}{{.State.Health.Status}}{{else}}-{{end}} | restarts={{.RestartCount}}' "$CONTAINER"
  else
    echo "$CONTAINER: <ยังไม่มี>"
  fi
}

wait_healthy() {
  local s
  for _ in $(seq 1 30); do
    s=$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || true)
    [[ "$s" == healthy ]] && return 0
    sleep 3
  done
  return 1
}

inspect() {
  echo "=== MONITORING INSPECT $(date -Is) ==="
  alloy_state
  docker stats --no-stream --format '{{.Name}} | mem {{.MemUsage}} | cpu {{.CPUPerc}}' "$CONTAINER" 2>/dev/null || true
  free -m 2>/dev/null || true
  if [[ -f "$ENV_FILE" ]]; then
    echo ".env: $(stat -c '%a %U' "$ENV_FILE" 2>/dev/null || echo '?')"
    check_env_keys || true
  else
    echo ".env: <ยังไม่มี> — รัน setup"
  fi
  role_state
  [[ -f "$BACKUP_LOG" ]] && echo "backup log: $BACKUP_LOG ($(wc -l <"$BACKUP_LOG") บรรทัด)" || echo "backup log: <ยังไม่มี $BACKUP_LOG>"
  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "--- alloy log (warn/error ล่าสุด) ---"
    docker logs --since 30m "$CONTAINER" 2>&1 | grep -E 'level=(warn|error)' | tail -n 15 || true
  fi
}

setup() {
  ensure_env_file
  docker inspect --format '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null | grep -qx true \
    || { echo "ไม่พบ container $PG_CONTAINER ที่รันอยู่" >&2; exit 1; }
  command -v openssl >/dev/null || { echo "ไม่พบ openssl" >&2; exit 1; }

  local u d pw out rc=0 tmp
  u=$(pg_env POSTGRES_USER); d=$(pg_env POSTGRES_DB)
  u=${u:-dormi}; d=${d:-dormi_v2}
  pw=$(openssl rand -hex 24)   # hex ล้วน: ปลอดภัยทั้งใน psql และ URL ไม่ต้อง escape

  # รหัสส่งทาง stdin (\set) — printf เป็น builtin จึงไม่โผล่ใน ps · กรองรหัสออกจาก output เผื่อ error
  out=$({ printf '\\set pw %s\n' "$pw"; cat "$SQL_FILE"; } \
        | docker exec -i "$PG_CONTAINER" psql -X -q -At -U "$u" -d "$d" 2>&1) || rc=$?
  printf '%s\n' "${out//$pw/[hidden]}"
  ((rc == 0)) || { echo "สร้าง role ไม่สำเร็จ (rc=$rc)" >&2; exit 1; }

  # เขียน DSN แทนบรรทัดเดิม (atomic: tmp → mv ในโฟลเดอร์เดียวกัน, umask 077 = 600)
  tmp=$(mktemp "$MON_DIR/.env.XXXXXX")
  SETUP_TMP=$tmp
  trap 'rm -f -- "${SETUP_TMP:-}"' EXIT   # พังกลางทาง = ไม่ทิ้งไฟล์ที่มีรหัสค้าง
  grep -v '^PG_MONITOR_DSN=' "$ENV_FILE" >"$tmp" || true
  printf 'PG_MONITOR_DSN=postgresql://dormi_monitor:%s@%s:5432/%s?sslmode=disable\n' "$pw" "$PG_CONTAINER" "$d" >>"$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$ENV_FILE"
  SETUP_TMP=""
  unset pw out
  echo "PG_MONITOR_DSN เขียนลง $ENV_FILE แล้ว (chmod 600, ไม่แสดงรหัส) · db=$d"

  if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "alloy รันอยู่ → recreate ให้ใช้รหัสใหม่"
    mcompose up -d --force-recreate
    wait_healthy || { echo "alloy ไม่ healthy หลัง recreate" >&2; exit 1; }
  fi
  echo SETUP_COMPLETE
}

up() {
  ensure_env_file
  check_env_keys || { echo "เติม key ที่ขาดใน $ENV_FILE ก่อน (PG_MONITOR_DSN: รัน setup)" >&2; exit 1; }
  docker network inspect "$NETWORK" >/dev/null 2>&1 || { echo "ไม่พบ network $NETWORK" >&2; exit 1; }
  # bind mount ไฟล์ที่ไม่มีอยู่ = docker สร้างเป็นโฟลเดอร์ แล้ว cron backup เขียน log ไม่ได้
  if [[ ! -e "$BACKUP_LOG" ]]; then
    install -m 644 /dev/null "$BACKUP_LOG"
    echo "สร้าง $BACKUP_LOG (ว่าง) แล้ว"
  fi
  [[ -f "$BACKUP_LOG" ]] || { echo "$BACKUP_LOG ไม่ใช่ไฟล์ปกติ" >&2; exit 1; }
  mcompose config -q
  mcompose up -d
  if ! wait_healthy; then
    alloy_state
    docker logs --tail 50 "$CONTAINER" 2>&1 | grep -E 'level=(warn|error)' || true
    echo "MONITORING_UP_FAILED (ปิดได้ด้วย: $0 down)" >&2
    exit 1
  fi
  alloy_state
  docker stats --no-stream --format '{{.Name}} | mem {{.MemUsage}} | cpu {{.CPUPerc}}' "$CONTAINER"
  echo MONITORING_UP_COMPLETE
}

down() {
  mcompose down
  echo MONITORING_DOWN_COMPLETE
}

case "$MODE" in
  inspect) inspect; echo INSPECTION_COMPLETE ;;
  setup) setup ;;
  up) up ;;
  down) down ;;
esac
