#!/usr/bin/env bash
# Release landing (Next.js standalone) จาก image ที่ build มาแล้วใน GitHub Actions
#   inspect                      อ่านอย่างเดียว: container/RAM/ดิสก์/สถานะ cert edge-landing/nginx -t
#   deploy <tar.gz> <sha>        เช็กดิสก์ → docker load → tag :prev → up → healthy → ตรวจผ่าน edge → (พัง = rollback)
#   ensure-dummy-cert            สร้าง dummy cert edge-landing ใน dormi-edge ถ้ายังไม่มี (idempotent)
# รันบน server: bash /root/dormi-edge/deploy/dormi-landing/release.sh <mode> [args]
set -Eeuo pipefail
umask 077

MODE=${1:-inspect}
case "$MODE" in
  inspect|deploy|ensure-dummy-cert) ;;
  *) echo "usage: $0 inspect | deploy <image.tar.gz> <sha> | ensure-dummy-cert" >&2; exit 2 ;;
esac

EDGE_DIR=${EDGE_DIR:-/root/dormi-edge}
COMPOSE_FILE="$EDGE_DIR/deploy/dormi-landing/docker-compose.yml"
PROJECT=dormi-landing
SERVICE=dormi-landing
IMAGE_REPO=dormi-landing
EDGE_CONTAINER=dormi-edge
HOST=dormi-linkandrent.com
CERT_NAME=edge-landing
RELEASES_DIR=${RELEASES_DIR:-/root/dormi-releases/landing-images}
KEEP_TARBALLS=3
MIN_FREE_KB=3145728   # 3 GiB

# shellcheck source=/dev/null
. "$EDGE_DIR/deploy/lib/deploy-lock.sh"
deploy_lock "landing release $MODE"

# compose ต้องการ LANDING_IMAGE ทุกคำสั่ง (ps/down ด้วย) — ใส่ค่า placeholder ไว้ก่อน
export LANDING_IMAGE=${LANDING_IMAGE:-$IMAGE_REPO:prev}
lcompose() { docker compose -p "$PROJECT" -f "$COMPOSE_FILE" "$@"; }
cid() { lcompose ps -aq "$SERVICE" 2>/dev/null | head -n1; }

wait_healthy() {
  local id attempt
  for attempt in $(seq 1 30); do
    id=$(cid)
    [[ -n "$id" && "$(docker inspect --format '{{.State.Health.Status}}' "$id" 2>/dev/null || true)" == healthy ]] && return 0
    sleep 3
  done
  return 1
}

# "<http_code> <redirect_url>" ของ https://$HOST<path> ผ่าน edge (-k เพราะอาจยังเป็น dummy cert)
edge_probe() {
  curl -sk -o /dev/null --max-time 15 -w '%{http_code} %{redirect_url}' \
    --resolve "$HOST:443:127.0.0.1" "https://$HOST$1"
}

# หน้าแรก 200 และ /admin ต้อง redirect ไป /admin/login — retry เพราะ nginx re-resolve ชื่อ upstream ทุก ~10 วิ
verify_edge() {
  local attempt home admin acode aloc
  for attempt in $(seq 1 10); do
    home=$(edge_probe /) || home="000 "
    admin=$(edge_probe /admin) || admin="000 "
    acode=${admin%% *}
    aloc=${admin#* }
    if [[ "${home%% *}" == 200 && "$acode" =~ ^(302|307|308)$ && "$aloc" == "https://$HOST/admin/login"* ]]; then
      echo "EDGE_OK / -> ${home%% *} · /admin -> $acode $aloc"
      return 0
    fi
    echo "edge ยังไม่พร้อม (try $attempt/10): / -> ${home%% *} · /admin -> $acode ${aloc:-<no redirect>}"
    sleep 3
  done
  return 1
}

# dummy cert (self-signed 1 วัน) ให้ nginx โหลด 40-landing.conf ได้ก่อนออก cert จริง
ensure_dummy_cert() {
  docker exec "$EDGE_CONTAINER" sh -c '
    d=/etc/letsencrypt/live/$1
    if [ -s "$d/fullchain.pem" ] && [ -s "$d/privkey.pem" ]; then
      echo "cert $1 มีอยู่แล้ว — ข้าม"; exit 0
    fi
    mkdir -p "$d"
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
      -keyout "$d/privkey.pem" -out "$d/fullchain.pem" \
      -subj "/CN=dummy.edge.local" 2>/dev/null
    echo "สร้าง dummy cert $1 แล้ว"
  ' sh "$CERT_NAME"
}

# dummy | real | missing (+ วันหมดอายุ)
cert_state() {
  docker exec "$EDGE_CONTAINER" sh -c '
    f=/etc/letsencrypt/live/$1/fullchain.pem
    [ -s "$f" ] || { echo "CERT_STATE=missing"; exit 0; }
    issuer=$(openssl x509 -in "$f" -noout -issuer 2>/dev/null)
    end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null)
    case "$issuer" in
      *dummy.edge.local*) echo "CERT_STATE=dummy ($end)" ;;
      *) echo "CERT_STATE=real ($end) $issuer" ;;
    esac
  ' sh "$CERT_NAME"
}

reload_edge() {
  docker exec "$EDGE_CONTAINER" nginx -t
  docker exec "$EDGE_CONTAINER" nginx -s reload
}

preflight() {
  echo "=== PREFLIGHT $MODE $(date -Is) ==="
  docker ps --format '{{.Names}} | {{.Status}} | {{.Image}}'
  free -m
  df -h /var/lib/docker
  cert_state
  local id
  id=$(cid)
  if [[ -n "$id" ]]; then
    echo "landing container: $(docker inspect --format '{{.Name}} | {{.Config.Image}} | {{.Image}} | {{.State.Status}} | {{.State.Health.Status}}' "$id")"
  else
    echo "landing container: <ยังไม่มี — deploy ครั้งแรก>"
  fi
  docker images "$IMAGE_REPO" --format '{{.Repository}}:{{.Tag}} | {{.ID}} | {{.CreatedSince}} | {{.Size}}'
  docker exec "$EDGE_CONTAINER" nginx -t
  docker exec "$EDGE_CONTAINER" nginx -T 2>/dev/null | grep -q 'upstream dormi_landing_pool' \
    || echo "WARN: edge ยังไม่ได้โหลด 40-landing.conf (merge edge แล้ว reload ก่อน deploy)"
}

case "$MODE" in
  inspect)
    preflight
    echo INSPECTION_COMPLETE
    exit 0
    ;;
  ensure-dummy-cert)
    ensure_dummy_cert
    reload_edge
    cert_state
    echo DUMMY_CERT_READY
    exit 0
    ;;
esac

# ───────────────────────── deploy ─────────────────────────
TAR=${2:?usage: $0 deploy <image.tar.gz> <sha>}
SHA=${3:?usage: $0 deploy <image.tar.gz> <sha>}
[[ "$SHA" =~ ^[0-9a-f]{7,40}$ ]] || { echo "sha ไม่ถูกต้อง: $SHA" >&2; exit 2; }
test -s "$TAR" || { echo "ไม่พบไฟล์ image: $TAR" >&2; exit 2; }
NEW_IMAGE="$IMAGE_REPO:${SHA:0:7}"
PHASE=none
ROLLBACK_IMAGE=""
OLD_ID=""

rollback() {
  local rc=$?
  trap - ERR
  set +e
  echo "DEPLOY_FAILED sha=${SHA:0:7} phase=$PHASE"
  if [[ "$PHASE" == swap ]]; then
    if [[ -n "$ROLLBACK_IMAGE" ]]; then
      echo "ROLLBACK → $ROLLBACK_IMAGE"
      LANDING_IMAGE="$ROLLBACK_IMAGE" lcompose up -d --no-build
      wait_healthy && verify_edge
    else
      echo "ROLLBACK: ครั้งแรก ไม่มี image เดิมให้ถอย → down service landing (ไม่มีอะไรเสียหาย)"
      lcompose down
    fi
  fi
  # image ที่พังไม่ต้องเก็บ (~350MB ต่อตัว) — ลบเฉพาะเมื่อไม่ได้เป็นตัวที่ถอยกลับไปใช้
  if [[ "$PHASE" == swap && "$ROLLBACK_IMAGE" != "$NEW_IMAGE" ]]; then
    docker rmi "$NEW_IMAGE" >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
trap rollback ERR

ensure_dummy_cert   # 40-landing.conf อ้าง cert edge-landing — ไม่มีไฟล์ = nginx -t ใน preflight ล้มเหลว
preflight
test "$(df -Pk /var/lib/docker | awk 'NR==2 {print $4}')" -gt "$MIN_FREE_KB" || { echo "Need at least 3 GiB free"; exit 1; }

echo "=== LOAD $TAR ==="
docker load -i "$TAR"
docker image inspect "$NEW_IMAGE" >/dev/null   # tar ต้องมี tag นี้ (release.yml build เป็น dormi-landing:<short sha>)
NEW_ID=$(docker image inspect --format '{{.Id}}' "$NEW_IMAGE")

OLD_CID=$(cid)
if [[ -n "$OLD_CID" ]]; then
  OLD_ID=$(docker inspect --format '{{.Image}}' "$OLD_CID")
  if [[ "$OLD_ID" != "$NEW_ID" ]]; then
    docker tag "$OLD_ID" "$IMAGE_REPO:prev"
    ROLLBACK_IMAGE="$IMAGE_REPO:prev"
  else
    echo "image ใหม่ = image ที่รันอยู่ — ไม่แตะ :prev"
    ROLLBACK_IMAGE="$NEW_IMAGE"
  fi
else
  echo "FIRST_DEPLOY: ยังไม่มี container landing เดิม — ถ้าพัง rollback = down (ไม่มีอะไรให้ถอย)"
fi

echo "=== SWAP → $NEW_IMAGE ==="
PHASE=swap
LANDING_IMAGE="$NEW_IMAGE" lcompose up -d --no-build
wait_healthy
ensure_dummy_cert
reload_edge
verify_edge

PHASE=none
trap - ERR

# บันทึก + เก็บ tarball ล่าสุด $KEEP_TARBALLS ไฟล์
mkdir -p "$RELEASES_DIR"
echo "$(date -Is) | ${SHA:0:7} | $NEW_IMAGE | prev=${OLD_ID:-none}" >> "$RELEASES_DIR/RELEASES.log"
# shellcheck disable=SC2012
ls -1t "$RELEASES_DIR"/*.tar.gz 2>/dev/null | tail -n +$((KEEP_TARBALLS + 1)) | xargs -r rm -f -- || true
# ลบ tag image เก่า (เหลือ ตัวใหม่ + :prev + ตัวที่รันก่อนหน้า) ไม่งั้นดิสก์โตทีละ ~350MB
for t in $(docker images "$IMAGE_REPO" --format '{{.Tag}}'); do
  [[ "$t" == "${SHA:0:7}" || "$t" == prev ]] && continue
  tid=$(docker image inspect --format '{{.Id}}' "$IMAGE_REPO:$t" 2>/dev/null || true)
  [[ -n "$OLD_ID" && "$tid" == "$OLD_ID" ]] && continue
  docker rmi "$IMAGE_REPO:$t" >/dev/null 2>&1 || true
done

echo "LANDING_RELEASE_COMPLETE sha=${SHA:0:7} image=$NEW_IMAGE"
cert_state
docker ps --format '{{.Names}} | {{.Status}} | {{.Image}}'
