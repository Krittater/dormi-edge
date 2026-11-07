#!/usr/bin/env bash
# ตรวจเนื้อหา Grafana ที่เป็นโค้ด (ไม่ต้องต่อ Grafana จริง):
#   1. ทุก .json parse ได้ · alerts/*.yaml parse ได้
#   2. โครงสร้าง dashboard / alert rule ถูก (uid ไม่ซ้ำ, ชื่อไทย, condition อ้าง refId ที่มีจริง, datasource uid รู้จัก)
#   3. ทุก query PromQL อ้างเฉพาะชื่อ metric ที่อยู่ใน expected-metrics.txt (กันพิมพ์ชื่อ metric ผิดแล้ว alert เงียบ)
#   4. ไม่มีรูปแบบ token/secret หลุดในไฟล์
#   5. import.sh ผ่าน bash -n · terraform fmt -check ถ้ามี terraform
# ใช้: bash monitoring/grafana/test/validate.sh   → จบด้วย VALIDATE_PASS (exit 0) หรือ VALIDATE_FAIL (exit 1)
# ต้องมี python3 (หรือ python) + PyYAML — ใช้ python parse JSON/YAML แทน `jq empty` / `yq` (ไม่ต้องลงเครื่องมือเพิ่ม)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAFANA_DIR="$(cd "$HERE/.." && pwd)"
REPO_DIR="$(cd "$GRAFANA_DIR/../.." && pwd)"

# เลือก python ตัวแรกที่ import yaml ได้ (บน Windows python3 อาจเป็นตัวหลอกของ Microsoft Store)
PY=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import yaml' >/dev/null 2>&1; then PY="$cand"; break; fi
done
if [[ -z "$PY" ]]; then echo "VALIDATE_FAIL: ไม่พบ python3/python ที่มี PyYAML (pip install pyyaml)"; exit 1; fi

fail=0
note() { echo "  - $*"; }

"$PY" "$HERE/validate_content.py" "$GRAFANA_DIR" "$HERE/expected-metrics.txt" || fail=1

# import.sh
if [[ -f "$GRAFANA_DIR/import.sh" ]]; then
  bash -n "$GRAFANA_DIR/import.sh" || { note "import.sh: bash -n ไม่ผ่าน"; fail=1; }
else
  note "ไม่พบ monitoring/grafana/import.sh"; fail=1
fi
[[ -f "$GRAFANA_DIR/synthetic-checks.md" ]] || { note "ไม่พบ synthetic-checks.md"; fail=1; }
[[ -f "$REPO_DIR/monitoring/README.md" ]] || { note "ไม่พบ monitoring/README.md"; fail=1; }

# terraform fmt (ถ้ามีเครื่องมือ)
TF_FILE="$REPO_DIR/terraform/monitoring-alerts.tf"
if [[ -f "$TF_FILE" ]]; then
  # alert_emails ต้องไม่มีค่า default ใน repo
  if grep -Eq '^[[:space:]]*default[[:space:]]*=' "$TF_FILE"; then note "monitoring-alerts.tf: ห้ามมี default (alert_emails ต้องไม่มีค่าใน repo)"; fail=1; fi
  if command -v terraform >/dev/null 2>&1; then
    terraform fmt -check -diff "$TF_FILE" || { note "terraform fmt ไม่ผ่าน"; fail=1; }
  else
    echo "  (ไม่มี terraform ในเครื่อง — ข้าม fmt)"
  fi
else
  note "ไม่พบ terraform/monitoring-alerts.tf"; fail=1
fi

if ((fail)); then echo "VALIDATE_FAIL"; exit 1; fi
echo "VALIDATE_PASS"
