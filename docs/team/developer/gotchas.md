# Developer gotchas — dormi-edge

## Monitoring (Grafana Alloy) — `deploy/monitoring/`
- Alloy pin `grafana/alloy:v1.20.1` · format ด้วย `alloy fmt` (ใช้ tab) ก่อน commit: `docker run --rm -v "$PWD/deploy/monitoring:/m" grafana/alloy:v1.20.1 fmt /m/config.alloy`
- กติกาตัด PII อยู่ `pii.alloy` ที่เดียว (declare module, import ด้วย `file.path_join(module_path, ...)`) — แก้แล้วรัน `bash deploy/monitoring/test/run-redact-check.sh` ต้องได้ `REDACT_CHECK_PASS`
- Nest logger ใส่รหัสสี ANSI เสมอ (แม้ไม่มี TTY) → regex ที่จับ `[HttpRequest] {json}` ต้องลบ `\x1b[..m` ก่อน (stage 0 ใน pii.alloy)
- cAdvisor ใน Alloy 1.20: docker factory ต้องมี `/run/containerd/containerd.sock` ไม่งั้นเห็นแค่ root cgroup (ไม่มี error ระดับ warn ให้เห็น) · ต้อง `cgroup: host` · network ต่อ container ต้อง `pid: host`
- cAdvisor metric kind `disk` ต้อง mount `/var/lib/docker` ทั้งก้อน — ปิดไว้ (ไม่งั้น error ทุกรอบ)
- `prometheus.exporter.*` ตั้ง label `job="integrations/<x>"` เอง — `job_name` ใน `prometheus.scrape` ไม่ทับ
- node exporter ใน container: `/proc/net` = network ของ container เอง → ไม่ใช้ netdev, ใช้ `container_network_*{id="/"}`
- `loki.source.docker`/`loki.source.file` อ่านย้อนหลังทั้งหมดตอนเปิดครั้งแรก → `stage.drop older_than` + ใช้เวลาจากบรรทัด backup (ไม่งั้น FAILED เก่าเข้าเป็น "ตอนนี้")
- bind mount ไฟล์ที่ host ยังไม่มี = docker สร้างเป็นโฟลเดอร์ → `monitoring.sh up` สร้าง `/var/log/dormi-db-backup.log` ก่อน
- ทดสอบในเครื่อง (Docker Desktop): `/:/host/root:ro,rslave` ใช้ไม่ได้ (root ไม่ใช่ shared mount) → override เป็น `:ro` เฉพาะตอนทดสอบ; git-bash ต้อง `MSYS_NO_PATHCONV=1` กับ `docker run` ที่มี path ขึ้นต้น `/`
- ทดสอบ `monitoring.sh` ในเครื่อง: รันใน `docker:29.9.1-cli` + `apk add bash openssl util-linux`, mount repo เป็น `/root/dormi-edge`, ตั้ง `PG_CONTAINER` และ `DEPLOY_LOCK_FILE=/tmp/...`
- pg_stat_statements ต้องมี `shared_preload_libraries` + `CREATE EXTENSION` — ไม่มี = alloy log `collector failed ... stat_statements` ทุกนาที (ไม่กระทบ metric อื่น)
- `loki.source.docker`: stdout+stderr ใน stream เดียวเวลาสลับลำดับ → Loki ตอบ `entry too far behind` → แยกด้วย label `stream`
- Loki local (`local-config.yaml`) query ingester แค่ 3 ชม. ล่าสุด (`query_ingesters_within`) → log ที่ timestamp เก่ากว่า 3 ชม. "หาย" ตอน query ในเครื่อง ไม่ใช่ pipeline ทิ้ง
- `process_resident_memory_bytes` ของ alloy ไม่ใช่ตัววัด OOM — ดู `docker stats` / `container_memory_working_set_bytes{name="dormi-alloy"}`
