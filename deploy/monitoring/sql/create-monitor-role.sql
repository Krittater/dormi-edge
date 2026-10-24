-- ============================================================
-- role อ่านอย่างเดียวสำหรับ Alloy (prometheus.exporter.postgres)
-- ------------------------------------------------------------
-- เรียกผ่าน `monitoring.sh setup` เท่านั้น — รหัสผ่านส่งเป็น psql variable `pw` ทาง stdin
--   (\set pw ... บรรทัดแรก) ไม่ผ่าน argv จึงไม่โผล่ใน `ps` / log
-- รันซ้ำได้ (idempotent): มี role แล้ว = เปลี่ยนรหัสเป็นค่าใหม่
-- สิทธิ์: pg_monitor (อ่าน pg_stat_* / pg_settings / ขนาด DB) — ไม่มีสิทธิ์อ่าน/เขียนตารางข้อมูลแอป
-- ============================================================
\set ON_ERROR_STOP on
\set VERBOSITY terse

-- คำสั่งที่มีรหัสผ่านต้องไม่ถูกบันทึกลง log ของ Postgres / pg_stat_statements
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET pg_stat_statements.track_utility = off;

SELECT 'CREATE ROLE dormi_monitor'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'dormi_monitor')
\gexec

ALTER ROLE dormi_monitor WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION CONNECTION LIMIT 5 PASSWORD :'pw';

GRANT pg_monitor TO dormi_monitor;

SELECT 'MONITOR_ROLE_READY' AS status;
