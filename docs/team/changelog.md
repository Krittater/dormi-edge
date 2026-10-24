# Changelog (ทีม) — dormi-edge

เรียงใหม่ → เก่า

- 2026-10-24 · developer · `deploy/monitoring/` ใหม่: Grafana Alloy (`dormi-alloy`, 256m) เก็บ host/container/Postgres/แอป + log ทุก container + log backup → Grafana Cloud · ตัด PII ใน `pii.alloy` · คำสั่ง `monitoring.sh inspect|setup|up|down` · edge/certbot มี log rotation 10m×3 (มีผลเมื่อ recreate) · devops: ต้องเติม `.env` (GRAFANA_*) และ `setup` ก่อน `up`; pg_stat_statements ยังไม่เปิดบน prod (ต้อง restart DB = ขออนุมัติ)
