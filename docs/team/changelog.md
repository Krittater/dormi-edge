# Changelog (ทีม) — dormi-edge

เรียงใหม่ → เก่า

- 2026-10-24 · developer · `deploy/backup/db-dump-to-spaces.sh` tar volume `dormi_files_data` (รูปสลิป) ขึ้น Spaces `files/<UTC date>.tar.gz` ทุกรอบ cron (เก็บ 14 วันตาม lifecycle ทั้ง bucket) · `upload` รับ key เต็มแล้ว (`daily/…`) · log marker: `OK files/… <bytes>`, `FAILED: files: …` (exit 5), บรรทัดสุดท้าย `<ISO> DONE <unix ts>` เฉพาะเมื่อสำเร็จครบ — Task 7 alert ใช้ · devops: server ต้องมี image `alpine:3.20` (pull ครั้งแรกอัตโนมัติ) และ user ที่รัน cron เรียก docker ได้ (root อยู่แล้ว) · กู้รูปดู `deploy/README.md` §6
- 2026-10-24 · developer · `deploy/monitoring/` ใหม่: Grafana Alloy (`dormi-alloy`, 256m) เก็บ host/container/Postgres/แอป + log ทุก container + log backup → Grafana Cloud · ตัด PII ใน `pii.alloy` · คำสั่ง `monitoring.sh inspect|setup|up|down` · edge/certbot มี log rotation 10m×3 (มีผลเมื่อ recreate) · devops: ต้องเติม `.env` (GRAFANA_*) และ `setup` ก่อน `up`; ถ้า prod ยังไม่เปิด pg_stat_statements (ดูจาก `monitoring.sh inspect`) จะต้อง restart DB เพื่อเปิด = ขออนุมัติ · docker.sock/containerd.sock = สิทธิ์ root (ยอมรับความเสี่ยง, no-new-privileges)
