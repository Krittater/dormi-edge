# Changelog (ทีม) — dormi-edge

เรียงใหม่ → เก่า

- 2026-10-24 · developer · `deploy/monitoring/` ใหม่: Grafana Alloy (`dormi-alloy`, 256m) เก็บ host/container/Postgres/แอป + log ทุก container + log backup → Grafana Cloud · ตัด PII ใน `pii.alloy` · คำสั่ง `monitoring.sh inspect|setup|up|down` · edge/certbot มี log rotation 10m×3 (มีผลเมื่อ recreate) · devops: ต้องเติม `.env` (GRAFANA_*) และ `setup` ก่อน `up`; ถ้า prod ยังไม่เปิด pg_stat_statements (ดูจาก `monitoring.sh inspect`) จะต้อง restart DB เพื่อเปิด = ขออนุมัติ · docker.sock/containerd.sock = สิทธิ์ root (ยอมรับความเสี่ยง, no-new-privileges)
