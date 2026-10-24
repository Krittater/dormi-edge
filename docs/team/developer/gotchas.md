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
- pg_stat_statements ต้องมี `shared_preload_libraries` + `CREATE EXTENSION` — ถ้า DB ยังไม่เปิด alloy จะ log `collector failed ... stat_statements` ทุกนาที (ไม่กระทบ metric อื่น) · ตรวจด้วย `monitoring.sh inspect`
- nginx error_log ออก stderr ของ container เดียวกับ access log และเป็นข้อความอิสระ (`request: "GET /x?.."`, `upstream:`, `referrer:`) — regex ของ JSON ไม่ครอบ ต้องมี stage แยก
- Postgres log มีค่าที่ผู้ใช้ส่งมาหลายที่: `DETAIL: Failing row`/`Key (..)=(..)`, `STATEMENT:` + บรรทัดต่อ (tab), `CONTEXT:`/`QUERY:`, `type uuid: "<ค่า>"`, `Token "<ค่า>"` → stage เฉพาะ container postgres ใน pii.alloy (มี negative test ว่าไม่แตะ container อื่น)
- socket (`docker.sock`) ใส่ `:ro` ไม่ได้ทำให้อ่านอย่างเดียว — API ยังสั่งได้ทุกอย่าง
- `loki.source.docker`: stdout+stderr ใน stream เดียวเวลาสลับลำดับ → Loki ตอบ `entry too far behind` → แยกด้วย label `stream`
- Loki local (`local-config.yaml`) query ingester แค่ 3 ชม. ล่าสุด (`query_ingesters_within`) → log ที่ timestamp เก่ากว่า 3 ชม. "หาย" ตอน query ในเครื่อง ไม่ใช่ pipeline ทิ้ง
- `process_resident_memory_bytes` ของ alloy ไม่ใช่ตัววัด OOM — ดู `docker stats` / `container_memory_working_set_bytes{name="dormi-alloy"}`

## Backup (`deploy/backup/`)
- volume รูปสลิปจริงบน prod = `dormi_files_data` (ไม่ใช่ `docker_dormi_files_data` ที่ว่าง) · `docker run -v <ชื่อที่ไม่มี>` สร้าง volume ว่างเงียบ ๆ → สคริปต์ตรวจ `docker volume inspect` ก่อนเสมอ
- `upload <file> <key เต็ม>` — key ต้องมี prefix เอง (`daily/…` หรือ `files/…`) · lifecycle 14 วันของ bucket ครอบทั้ง bucket จึงไม่ต้องอยู่ใต้ `daily/`
- marker ใน `/var/log/dormi-db-backup.log` (Alloy → alert): `DONE <unix ts>` เฉพาะเมื่อ DB+ไฟล์ครบ · `FAILED: …` · ไฟล์ล้ม = exit 5 โดย DB ที่อัปแล้วยังมี `OK`
- test-db-dump.sh ใช้ `docker` ปลอมใน `$d/bin` (นำหน้า PATH) + uploader ปลอม — ไม่แตะ docker/Spaces จริง · รันบน Git Bash Windows ช้า (หลายนาที) เพราะ spawn process เยอะ
- ใน Git Bash `grep -c $'\r'` ภายใน `$(…)`/for ได้ผลเท่ากับนับทุกบรรทัด (ใช้เช็ก CRLF ไม่ได้) → ใช้ `od -c | head` แทน · `.sh` ต้อง LF (ดู .gitattributes)

## Grafana content (`monitoring/grafana/`, `terraform/monitoring-alerts.tf`)
- ตรวจไฟล์: `bash monitoring/grafana/test/validate.sh` → `VALIDATE_PASS` (ใช้ python + PyYAML แทน jq/yq · บน Windows `python3` อาจเป็นตัวหลอกของ MS Store — สคริปต์เลือกตัวที่ `import yaml` ได้) · ชื่อ metric ใหม่ใน query ต้องเพิ่มใน `test/expected-metrics.txt` ก่อน (หลังยืนยันว่ามีจริง)
- label `job` ของ `dormi_job_*` ชนกับ job="dormi-app" ของ scrape → ถ้า `honor_labels` เป็น false (ค่าเริ่มต้นของ Alloy) จะกลายเป็น `exported_job` และ alert งานเงียบหมด → `prometheus.scrape "app"` ต้องมี `honor_labels = true` (ทดสอบกับ alloy v1.20.1)
- alert งานใช้ `max by (job)` ข้าม replica เสมอ — replica ที่ไม่ใช่ scheduler ค้างค่า **`last_success` เท่านั้น** (`initGauges()` โหลดจาก DB ตอน boot) · `last_run` ถูกตั้งแค่ใน `JobRunService.record()` ที่รันบน scheduler → scheduler ดับ/เข้าถึงไม่ได้ = series หาย (ไม่ใช่ค่าเก่า) → alert "งานทุกนาทีหยุดรัน" ต้อง `noDataState: Alerting` · เมื่อ app ดับทั้งหมด (scrape ล้ม = stale) มี rule "แอปหรือตัวเก็บข้อมูลหยุดส่งข้อมูล" (`max(up{job="dormi-app"}) or vector(0)`) เป็นตัวกันเหนียว
- "งานล้ม" อย่าใช้ `increase(dormi_job_runs_total{status="failed"})` เป็นตัวตัดสิน: counter เริ่มที่ 1 ตอนล้มครั้งแรก (increase = 0) และรีเซ็ตตอน restart → ใช้ `last_run > last_success` (success ตั้งสองค่าเท่ากัน) · ตัวนับใช้ประกอบเท่านั้น (dashboard ติดป้าย "นับตั้งแต่ restart")
- Grafana 11.3: `PUT /api/v1/provisioning/folder/<uid>/rule-groups/<g>` กับ rule ที่มี uid แต่ยังไม่เคยมี → 500 (`could not find alert rule`) → import.sh สร้างทีละ rule (GET → 404 → POST) ก่อนแล้วค่อย PUT group
- `GET /api/folders/<uid>` ของโฟลเดอร์ที่ยังไม่มีตอบ **403** (ไม่ใช่ 404) → import.sh ดูจากรายการ `GET /api/folders`
- Loki instant query ที่คืนหลายบรรทัด: Grafana 11 รวมเป็นตารางเดียว (feature | Value) → bargauge ต้อง `reduceOptions.values = true` ไม่งั้นได้ตัวเลขเดียว · LogQL `regexp` ที่ไม่ match ทำให้ label ว่างกลายเป็นอีกกลุ่ม → ใส่ line filter (`|= ...`) ก่อน regexp (ไม่งั้นนับหอเกินไป 1)
- regex ใน PromQL ใช้ backtick (raw string) — ไม่ต้อง escape แบ็กสแลชซ้อนสองชั้นใน JSON/YAML
- import.sh: token ไปทาง `curl --config -` (stdin) · python บน Windows เขียน text เป็น CRLF → ไฟล์ที่ bash อ่านด้วย `read` ต้องเปิดด้วย `newline=""` · ค่า datasource uid ตั้งทับได้ด้วย `PROM_DS_UID`/`LOKI_DS_UID`
- ทดสอบกับ Grafana local: container `obstest-*` (prom v3.13.4 `--web.enable-remote-write-receiver`, loki 3.7.8, grafana-oss 11.3.1, alloy 1.20.1, postgres:16-alpine + pg_stat_statements) · สร้าง datasource uid `grafanacloud-prom`/`grafanacloud-logs` · สร้าง service account Editor + token ผ่าน API · ลบ container/network หลังจบ
- `terraform validate` ต้อง `init` (โหลด provider) — ทำใน copy นอก repo (คัดลอก `*.tf` + `.terraform.lock.hcl`) แล้ว `terraform init -backend=false && terraform validate` · `alert_emails` ไม่มี default → `plan`/`apply` ทุกครั้ง (รวม resize) ต้องมี `terraform.tfvars`
- heredoc ในเครื่องมือ bash ลดแบ็กสแลชคู่เหลือตัวเดียว → ไฟล์ที่มีแบ็กสแลช (regex, HCL) เขียนด้วย Write/Edit ไม่ใช่ heredoc
