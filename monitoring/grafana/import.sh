#!/usr/bin/env bash
# นำเข้า dashboard "Dormi ภาพรวม" + alert rules ไปที่ Grafana (Cloud หรือ local) — รันซ้ำได้ (เขียนทับของเดิม)
#
#   GRAFANA_URL=https://<stack>.grafana.net GRAFANA_SA_TOKEN=<token> bash monitoring/grafana/import.sh
#
#   GRAFANA_URL       ที่อยู่ Grafana ไม่ต้องมี / ท้าย (บังคับ https ยกเว้น localhost/127.0.0.1)
#   GRAFANA_SA_TOKEN  token ของ service account `dormi-provisioner` (สิทธิ์ Editor, H4) — อ่านจาก env เท่านั้น
#                     สคริปต์ไม่พิมพ์ token, ไม่ใส่ในพารามิเตอร์ของคำสั่ง (ส่งให้ curl ผ่าน stdin) · ห้ามรันด้วย `bash -x`
#   PROM_DS_UID / LOKI_DS_UID   (ไม่บังคับ) ถ้า stack ใช้ datasource uid ไม่ตรงมาตรฐาน
#                     (ค่าเริ่มต้น grafanacloud-prom / grafanacloud-logs ซึ่งเป็น uid มาตรฐานของ Grafana Cloud)
#   ONLY=dashboard|alerts   (ไม่บังคับ) ทำเฉพาะอย่างเดียว
#   DRY_RUN=1         สร้าง payload แล้วแสดงสรุป ไม่ต่อเครือข่าย ไม่ต้องมี token (ใช้ตรวจไฟล์)
#
# ทำอะไร: สร้างโฟลเดอร์ "Dormi" (uid dormi) ถ้ายังไม่มี → POST /api/dashboards/db (overwrite)
#         → PUT /api/v1/provisioning/folder/dormi/rule-groups/<group> ทีละ group (แทนที่ทั้ง group)
#         rule ที่ส่งด้วย X-Disable-Provenance: แก้ใน UI ได้ (แต่รอบ import ถัดไปจะเขียนทับ)
# ไม่ทำ: contact point / notification policy (ตั้งใน UI, H5) · Synthetic check (ดู synthetic-checks.md)
# ต้องมี: bash, curl, python3 (หรือ python) + PyYAML
set -Eeuo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASH_FILE="$HERE/dashboards/dormi-overview.json"
ALERT_FILE="$HERE/alerts/dormi-alerts.yaml"
FOLDER_UID=dormi
FOLDER_TITLE=Dormi
ONLY=${ONLY:-all}
DRY_RUN=${DRY_RUN:-0}
PROM_DS_UID=${PROM_DS_UID:-grafanacloud-prom}
LOKI_DS_UID=${LOKI_DS_UID:-grafanacloud-logs}

die() { echo "ผิดพลาด: $*" >&2; exit 1; }

case "$ONLY" in all|dashboard|alerts) ;; *) die "ONLY ต้องเป็น dashboard หรือ alerts" ;; esac
[[ -f "$DASH_FILE" && -f "$ALERT_FILE" ]] || die "ไม่พบไฟล์ dashboard/alerts ข้างสคริปต์"

# python ตัวแรกที่ import yaml ได้ (บน Windows python3 อาจเป็นตัวหลอกของ Microsoft Store)
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import yaml' >/dev/null 2>&1; then PY="$cand"; break; fi
done
export PYTHONUTF8=1 PYTHONIOENCODING=utf-8   # คอนโซล Windows เป็น cp1252 โดยปริยาย ข้อความไทยจะพัง
[[ -n "$PY" ]] || die "ต้องมี python3 (หรือ python) ที่ติดตั้ง PyYAML (pip install pyyaml)"

if [[ "$DRY_RUN" != "1" ]]; then
  command -v curl >/dev/null 2>&1 || die "ต้องมี curl"
  [[ -n "${GRAFANA_URL:-}" ]] || die "ต้องตั้ง GRAFANA_URL (เช่น https://dormi.grafana.net)"
  [[ -n "${GRAFANA_SA_TOKEN:-}" ]] || die "ต้องตั้ง GRAFANA_SA_TOKEN (token ของ service account dormi-provisioner)"
  GRAFANA_URL="${GRAFANA_URL%/}"
  case "$GRAFANA_URL" in
    https://*) ;;
    http://localhost*|http://127.0.0.1*) ;;
    *) die "GRAFANA_URL ต้องขึ้นต้นด้วย https:// (ยกเว้น localhost)" ;;
  esac
  # token ใส่ใน config ของ curl ที่ส่งทาง stdin → ห้ามมีอักขระที่ทำให้ config เพี้ยน
  [[ "$GRAFANA_SA_TOKEN" =~ ^[A-Za-z0-9_.=+/-]+$ ]] || die "GRAFANA_SA_TOKEN มีอักขระที่ไม่คาดคิด (ตรวจว่าคัดลอกมาครบ ไม่มีช่องว่าง/ขึ้นบรรทัดใหม่)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ── แปลงไฟล์เป็น payload ของ API (แทน datasource uid ถ้าตั้งไว้) ──
"$PY" - "$DASH_FILE" "$ALERT_FILE" "$WORK" "$FOLDER_UID" "$FOLDER_TITLE" "$PROM_DS_UID" "$LOKI_DS_UID" <<'PYEOF'
import json, re, sys
import yaml

dash_file, alert_file, work, folder_uid, folder_title, prom_uid, loki_uid = sys.argv[1:8]
STD = {"grafanacloud-prom": prom_uid, "grafanacloud-logs": loki_uid}


def sub_uid(o):
    """แทน uid ของ datasource ทั้งโครงสร้าง (เฉพาะ key 'uid' / 'datasourceUid')"""
    if isinstance(o, dict):
        return {k: (STD.get(v, v) if k in ("uid", "datasourceUid") and isinstance(v, str) else sub_uid(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [sub_uid(x) for x in o]
    return o


def to_seconds(s):
    m = re.fullmatch(r"(\d+)([smh])", str(s))
    if not m:
        raise SystemExit(f"interval ไม่ถูกรูปแบบ: {s}")
    return int(m.group(1)) * {"s": 1, "m": 60, "h": 3600}[m.group(2)]


with open(dash_file, encoding="utf-8") as f:
    dash = sub_uid(json.load(f))
dash["id"] = None
body = {"dashboard": dash, "folderUid": folder_uid, "overwrite": True, "message": "import.sh (monitoring as code)"}
json.dump(body, open(f"{work}/dashboard.json", "w", encoding="utf-8"), ensure_ascii=False)

with open(alert_file, encoding="utf-8") as f:
    doc = yaml.safe_load(f)
manifest = []
rule_manifest = []
n_rules = 0
for i, g in enumerate(doc["groups"]):
    rules = []
    for r in g["rules"]:
        r = sub_uid(r)
        rule = {
            "uid": r["uid"], "title": r["title"], "condition": r["condition"], "data": r["data"],
            "noDataState": r["noDataState"], "execErrState": r["execErrState"], "for": r["for"],
            "annotations": r.get("annotations", {}), "labels": r.get("labels", {}),
            "isPaused": bool(r.get("isPaused", False)),
            "folderUID": folder_uid, "ruleGroup": g["name"], "orgID": g.get("orgId", 1),
        }
        rules.append(rule)
        rfn = f"rule-{r['uid']}.json"
        json.dump(rule, open(f"{work}/{rfn}", "w", encoding="utf-8"), ensure_ascii=False)
        rule_manifest.append(r["uid"] + "\t" + rfn)
    n_rules += len(rules)
    payload = {"title": g["name"], "folderUid": folder_uid, "interval": to_seconds(g["interval"]), "rules": rules}
    fn = f"group-{i}.json"
    json.dump(payload, open(f"{work}/{fn}", "w", encoding="utf-8"), ensure_ascii=False)
    manifest.append(f'{g["name"]}\t{fn}\t{len(rules)}')
# newline="" = ไม่แปลง \n เป็น \r\n บน Windows (ไม่งั้น bash อ่านชื่อไฟล์ผิด)
open(f"{work}/groups.tsv", "w", encoding="utf-8", newline="").write("\n".join(manifest) + "\n")
open(f"{work}/rules.tsv", "w", encoding="utf-8", newline="").write("\n".join(rule_manifest) + "\n")
print(f"เตรียม payload แล้ว: dashboard 1 ({len(dash['panels'])} รายการ), alert {n_rules} rule ใน {len(manifest)} group")
PYEOF

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN: ไม่ส่งอะไรไป Grafana"
  [[ "$ONLY" != "alerts" ]] && echo "  dashboard -> POST /api/dashboards/db (โฟลเดอร์ $FOLDER_TITLE)"
  if [[ "$ONLY" != "dashboard" ]]; then
    while IFS=$'\t' read -r name _ count; do
      [[ -n "$name" ]] && echo "  alerts    -> PUT /api/v1/provisioning/folder/$FOLDER_UID/rule-groups/$name ($count rule)"
    done < "$WORK/groups.tsv"
  fi
  exit 0
fi

# ── เรียก API: token ไปทาง stdin ของ curl (--config -) ไม่อยู่ในพารามิเตอร์ ──
RESP="$WORK/resp.txt"
call() { # call METHOD PATH [BODYFILE] → พิมพ์ HTTP status, เนื้อหาตอบกลับอยู่ที่ $RESP
  local method=$1 path=$2 body=${3:-}
  local args=(-sS -o "$RESP" -w '%{http_code}' --max-time 60 -X "$method"
    -H 'Content-Type: application/json' -H 'Accept: application/json' -H 'X-Disable-Provenance: true')
  [[ -n "$body" ]] && args+=(--data-binary "@$body")
  printf 'header = "Authorization: Bearer %s"\n' "$GRAFANA_SA_TOKEN" | curl --config - "${args[@]}" "$GRAFANA_URL$path"
}
fail_resp() { echo "ผิดพลาด: $1 (HTTP $2)" >&2; head -c 800 "$RESP" >&2 || true; echo >&2; exit 1; }

# โฟลเดอร์ Dormi — ดูจากรายการโฟลเดอร์ (GET /api/folders/<uid> ของโฟลเดอร์ที่ยังไม่มีจะตอบ 403 แทน 404)
code=$(call GET "/api/folders?limit=1000") || die "เชื่อมต่อ $GRAFANA_URL ไม่ได้"
case "$code" in
  200)
    if grep -Eq "\"uid\" *: *\"$FOLDER_UID\"" "$RESP"; then
      echo "โฟลเดอร์ $FOLDER_TITLE: มีอยู่แล้ว"
    else
      printf '{"uid":"%s","title":"%s"}' "$FOLDER_UID" "$FOLDER_TITLE" > "$WORK/folder.json"
      code=$(call POST /api/folders "$WORK/folder.json") || die "สร้างโฟลเดอร์ไม่ได้"
      [[ "$code" == 200 ]] || fail_resp "สร้างโฟลเดอร์ $FOLDER_TITLE ไม่สำเร็จ" "$code"
      echo "โฟลเดอร์ $FOLDER_TITLE: สร้างแล้ว"
    fi ;;
  401|403) fail_resp "token ไม่มีสิทธิ์/หมดอายุ (ต้องเป็น service account สิทธิ์ Editor)" "$code" ;;
  *) fail_resp "ตรวจโฟลเดอร์ไม่สำเร็จ" "$code" ;;
esac

if [[ "$ONLY" != "alerts" ]]; then
  code=$(call POST /api/dashboards/db "$WORK/dashboard.json") || die "ส่ง dashboard ไม่ได้"
  [[ "$code" == 200 ]] || fail_resp "นำเข้า dashboard ไม่สำเร็จ" "$code"
  echo "dashboard: นำเข้าแล้ว -> $GRAFANA_URL/d/dormi-overview"
fi

if [[ "$ONLY" != "dashboard" ]]; then
  # 1) rule ที่ยังไม่มี → สร้างก่อน (PUT group กับ rule ที่มี uid แต่ยังไม่เคยมี Grafana 11 ตอบ 500)
  while IFS=$'\t' read -r uid file; do
    [[ -n "$uid" ]] || continue
    code=$(call GET "/api/v1/provisioning/alert-rules/$uid") || die "ตรวจ alert rule $uid ไม่ได้"
    case "$code" in
      200) ;;
      404)
        code=$(call POST /api/v1/provisioning/alert-rules "$WORK/$file") || die "สร้าง alert rule $uid ไม่ได้"
        [[ "$code" == 201 || "$code" == 200 ]] || fail_resp "สร้าง alert rule $uid ไม่สำเร็จ" "$code" ;;
      *) fail_resp "ตรวจ alert rule $uid ไม่สำเร็จ" "$code" ;;
    esac
  done < "$WORK/rules.tsv"
  # 2) ส่งทั้ง group (กำหนดความถี่ + อัปเดตเนื้อ rule ทุกตัวให้ตรงไฟล์)
  while IFS=$'\t' read -r name file count; do
    [[ -n "$name" ]] || continue
    code=$(call PUT "/api/v1/provisioning/folder/$FOLDER_UID/rule-groups/$name" "$WORK/$file") || die "ส่ง alert group $name ไม่ได้"
    [[ "$code" == 200 ]] || fail_resp "นำเข้า alert group $name ไม่สำเร็จ" "$code"
    echo "alert group $name: นำเข้าแล้ว ($count rule)"
  done < "$WORK/groups.tsv"
  echo "ตรวจผลที่ $GRAFANA_URL/alerting/list"
fi
echo "IMPORT_OK"
