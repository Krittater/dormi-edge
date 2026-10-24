# Dormi Monitoring — คู่มือผู้บริหาร (1 หน้า)

ระบบเฝ้าดู Dormi อยู่บน **Grafana Cloud (แพ็กเกจฟรี — 0 บาท)** + แจ้งเตือนสำรองของ DigitalOcean
ข้อมูลส่วนบุคคล (ชื่อ อีเมล เบอร์ เลขบัตร ยอดเงิน) **ถูกตัดก่อนออกจากเครื่อง** — dashboard เห็นแค่จำนวนและความเร็ว ไม่เห็นตัวคน

เปิดดูที่: Grafana Cloud → Dashboards → โฟลเดอร์ **Dormi** → **"Dormi ภาพรวม"** (ปรับเองอัตโนมัติทุก 1 นาที · เวลาไทย)

## วิธีอ่าน dashboard — 4 แถว มองสี: เขียว = ปกติ, แดง = ต้องดู

| แถว | ตอบคำถาม | ปกติหน้าตาแบบไหน | ถ้าผิดปกติ |
|---|---|---|---|
| **ระบบปกติไหม** | ลูกค้าเข้าใช้ได้ไหม · ช้าไหม · cert ใกล้หมดไหม | 4 ช่องบนซ้ายเขียว "ปกติ" · error < 1% · ตอบ < 0.5 วินาที · cert > 30 วัน | ช่องแดง "ล่ม" = เว็บ/API นั้นเข้าไม่ได้ทันที (alert จะเด้งเอง) |
| **งานเบื้องหลัง** | ออกบิล ตรวจสลิป ฯลฯ ทำงานครบไหม · backup เมื่อคืนสำเร็จไหม | "ล้มใน 7 วัน" = 0 ทุกแถว · "สำเร็จล่าสุด" ของออกบิลรายวัน < 26 ชม. · backup ล่าสุดไม่เกิน 1 วัน | ตัวเลขแดง = งานนั้นล้ม/หยุด ผู้เช่าอาจไม่ได้รับบิลหรือสลิปค้าง |
| **การใช้งานฟีเจอร์** | ฟีเจอร์ไหนมีคนใช้ · กี่หอใช้ · ตัวไหนช้า | (ไม่มีเกณฑ์ผิด/ถูก) ใช้ตัดสินใจว่าจะพัฒนาอะไรต่อ | ฟีเจอร์ที่ "จำนวนหอ" ต่ำมากต่อเนื่อง = ไม่คุ้มลงทุนต่อ · ฟีเจอร์ที่ช้าสุด = ควรปรับก่อน |
| **ทรัพยากร** | เครื่องรับไหวไหม · ดิสก์จะเต็มเมื่อไร · ฐานข้อมูลสบายดีไหม | CPU/RAM < 75% · ดิสก์ < 70% · "ดิสก์จะเหลือว่าง" เป็นบวก · cache hit > 95% | "ดิสก์จะเหลือว่างอีก 7 วัน" ติดลบ = คาดว่าเต็มภายใน 7 วัน ควรเคลียร์/ขยายดิสก์ |

ช่องที่ขึ้น "ไม่มีข้อมูล" ไม่ใช่ความผิดปกติเสมอไป: ในช่วงแรกยังไม่มี check ภายนอก/ยังไม่เปิด pg_stat_statements ฯลฯ — ดูคำอธิบายที่ไอคอน (i) มุมบนซ้ายของแต่ละช่อง

## alert ที่จะแจ้งเตือน (ชื่อภาษาไทย ส่งเข้าอีเมล/Telegram ที่ตั้งไว้)

| alert | ดังเมื่อ | ความหมาย |
|---|---|---|
| เว็บ/API ล่ม | ตรวจจากภายนอกไม่ผ่าน 2 รอบติด (~4 นาที) | ลูกค้าเข้าไม่ได้ — เร่งด่วนสุด |
| error พุ่ง | request ล้มเหลว (5xx) > 2% ใน 10 นาที (อย่างน้อย 20 request) | ระบบมีปัญหาแม้เว็บยังเปิด |
| ออกบิลรายวันไม่สำเร็จ | งานออกบิลล้ม หรือไม่สำเร็จเกิน 26 ชม. | ผู้เช่าอาจไม่ได้รับบิล |
| งานทุกนาทีหยุดรัน | คำนวณน้ำไฟ/ตรวจสลิปซ้ำ หยุดเกิน 10 นาที | scheduler ค้าง |
| backup ไม่สำเร็จ (2 แบบ) | ไม่เห็นบรรทัด DONE เกิน 26 ชม. หรือเห็น FAILED: | ข้อมูลอาจไม่มีสำรอง |
| ดิสก์จะเต็ม | ใช้เกิน 80% หรือคาดว่าเต็มใน 7 วัน | ก่อนระบบหยุดเพราะดิสก์เต็ม |
| RAM ตึง | RAM ว่างน้อยกว่า 10% นาน 10 นาที | ระบบอาจช้า/container ถูกฆ่า |
| cert ใกล้หมด | ใบรับรอง https เหลือ < 14 วัน | การต่ออายุอัตโนมัติไม่ทำงาน |
| DB connection ใกล้เต็ม | ใช้เกิน 80% ของเพดาน | แอปอาจต่อฐานข้อมูลไม่ได้ |
| แอปหรือตัวเก็บข้อมูลหยุดส่งข้อมูล | ไม่มีข้อมูลจากแอปเกิน 5 นาที | ตัวกันเหนียว: ถ้าตัวเก็บข้อมูลดับ alert อื่นจะเงียบ จึงต้องมีตัวนี้ |

สำรองอีกชั้นที่ **ไม่พึ่ง Grafana**: DigitalOcean ส่งอีเมลเมื่อดิสก์ > 85%, RAM > 90%, CPU > 90% (10 นาที) — ตั้งด้วย Terraform (`terraform/monitoring-alerts.tf`)

## ขั้นตอนที่ผู้บริหารต้องทำเอง (H1–H7)

ทำ H1–H2, H4–H6 คู่ขนานระหว่างที่ทีมพัฒนาได้ · ทำตามลำดับตัวเลขตอน deploy (ลำดับ deploy จริงอยู่ใน `docs/pipeline/monitoring/06-release.md`)

| # | ทำอะไร | ได้อะไรมา | ใส่ที่ไหน |
|---|---|---|---|
| **H1** | สมัคร Grafana Cloud (grafana.com → Free, ไม่ใส่บัตร) ด้วยอีเมลบริษัท · สร้าง stack ชื่อ `dormi` เลือก region ที่ใกล้ไทยที่สุด | URL ของ stack เช่น `https://dormi.grafana.net` (ไม่ลับ) | บอกทีม |
| **H2** | ใน stack: Connections → Hosted Prometheus metrics / Hosted logs → สร้าง Access Policy token สิทธิ์ `metrics:write` + `logs:write` | URL ปลายทาง + username (ไม่ลับ) + **token (ลับ)** | `deploy/monitoring/.env` บน server (chmod 600) — **ห้ามส่งทางแชท/อีเมล/ใส่ใน git** |
| **H3** | Frontend Observability → สร้าง app `dormi-web` (allowed origin `https://app.dormi-linkandrent.com`) | Faro collector URL | `.env.production` ของ frontend ตอน deploy |
| **H4** | Administration → Service accounts → สร้าง `dormi-provisioner` สิทธิ์ **Editor** → สร้าง token | **token (ลับ)** | ใช้รันคำสั่งนำเข้าด้านล่างบนเครื่องของคุณเอง |
| **H5** | เลือกช่องทางแจ้งเตือน: Alerting → Contact points → เพิ่ม **อีเมล** (บังคับ) + Telegram (ถ้าต้องการ) → Notification policies → ตั้ง default ให้ส่งไป contact point นั้น | — | ตั้งใน Grafana UI เอง (ไฟล์ในนี้ไม่ใส่ผู้รับ) |
| **H6** | กำหนดอีเมลผู้รับ **สรุปรายสัปดาห์** | รายชื่ออีเมล | env `OBS_WEEKLY_REPORT_TO` บน server ตอน deploy |
| **H7** | อนุมัติ `terraform apply` สร้าง alert สำรองของ DigitalOcean (ฟรี) | — | ดูคำสั่งด้านล่าง |

### ลำดับนำเข้า (หลัง deploy monitoring + backend ขึ้น server แล้ว)

1. **สร้าง Synthetic checks 4 ตัว** ตาม [`grafana/synthetic-checks.md`](grafana/synthetic-checks.md) (ประมาณ 10 นาที ใน UI)
2. **นำเข้า dashboard + alert rules** (รันบนเครื่องคุณ — token อยู่ในหน่วยความจำของ session นี้เท่านั้น ไม่ถูกบันทึก):
   ```bash
   export GRAFANA_URL=https://dormi.grafana.net        # URL จาก H1
   read -rs GRAFANA_SA_TOKEN && export GRAFANA_SA_TOKEN # วาง token จาก H4 แล้วกด Enter (ไม่แสดงบนจอ)
   bash monitoring/grafana/import.sh
   ```
   รันซ้ำได้ปลอดภัย (เขียนทับของเดิม) · ต้องมี `curl` และ `python3` + `pip install pyyaml` · ดูก่อนโดยไม่ส่งจริง: `DRY_RUN=1 bash monitoring/grafana/import.sh`
   ★ ถ้า stack ของคุณใช้ datasource uid ไม่ใช่ `grafanacloud-prom` / `grafanacloud-logs` ให้ตั้ง `PROM_DS_UID` / `LOKI_DS_UID` (ดูที่ Connections → Data sources → uid ใน URL)
3. **ตั้งผู้รับ alert (H5)** แล้วกด **Test** ที่ contact point ให้เห็นอีเมลเข้าจริง
4. **DigitalOcean alert (H7):**
   ```powershell
   cd terraform
   $env:DIGITALOCEAN_TOKEN = "<token>"      # ดู terraform/README.md ตอนเริ่มใช้
   Set-Content terraform.tfvars 'alert_emails = ["ชื่อ@บริษัท.com"]'   # ไฟล์นี้ถูก .gitignore กันไว้แล้ว ไม่ถูก commit
   terraform plan                            # ต้องเห็น: Plan: 3 to add, 0 to change, 0 to destroy
   terraform apply                           # พิมพ์ yes เมื่อพอใจ
   ```
   ถ้า plan ขึ้นว่าจะ **change/destroy** อะไรก็ตาม → **หยุด** แล้วเรียกทีมเทคนิค (ถ้าเครื่องนี้ยังไม่เคยรัน Terraform ของโปรเจกต์มาก่อน plan จะมี "import" ของ droplet เพิ่มด้วย — ให้ทีมเทคนิคตรวจก่อน)

### เช็คว่าใช้ได้จริง (5 นาทีหลังนำเข้า)

- dashboard แถว "ระบบปกติไหม" มี 4 ช่องเขียว · แถว "งานเบื้องหลัง" ขึ้นรายชื่องานครบ
- Alerting → Alert rules → โฟลเดอร์ Dormi: 11 rules สถานะ Normal (ไม่ใช่ Error)
- (ทดสอบ alert) Contact points → Test → อีเมลต้องเข้า

## สำหรับทีมเทคนิค

- **เนื้อหาเป็นโค้ดทั้งหมด:** `grafana/dashboards/dormi-overview.json`, `grafana/alerts/dormi-alerts.yaml`, `grafana/import.sh`, `terraform/monitoring-alerts.tf` — แก้ในไฟล์แล้ว import ใหม่ (การแก้ใน UI จะถูกเขียนทับรอบ import ถัดไป)
- **ตรวจไฟล์ก่อน commit:** `bash monitoring/grafana/test/validate.sh` → ต้องได้ `VALIDATE_PASS` (ตรวจ JSON/YAML, โครง alert, ชื่อ metric ทุกตัวต้องอยู่ใน `grafana/test/expected-metrics.txt`, ไม่มี secret)
- **ต้องพึ่ง:** `config.alloy` → `prometheus.scrape "app"` ต้องมี `honor_labels = true` (ไม่งั้น label `job` ของงาน เช่น `billing.daily` ถูกเปลี่ยนเป็น `exported_job` แล้ว alert/ตารางงานไม่เจอข้อมูล) · metric ของงานอ่านด้วย `max by (job)` เสมอ เพราะ replica api ที่ไม่ใช่ scheduler ค้างค่าตอน boot
- **Loki:** alert จาก log Postgres (ถ้าจะเพิ่ม) ต้องตัด error ของ `pg_stat_statements` ออก (prod อาจยังไม่มี extension)
- **secret:** token ทุกตัวอยู่ใน env/`.env` บน server หรือในเครื่องผู้รัน เท่านั้น — `import.sh` ไม่พิมพ์ token ไม่ส่งผ่านพารามิเตอร์คำสั่ง · `alert_emails` ไม่มีค่าใน repo
- **Rollback:** ปิดตัวเก็บข้อมูล `bash deploy/monitoring/monitoring.sh down` · ลบ alert: Grafana UI → โฟลเดอร์ Dormi → Delete · `terraform destroy -target=digitalocean_monitor_alert.disk_high` ฯลฯ (เฉพาะ 3 ตัวนี้ — ห้าม destroy ทั้งโฟลเดอร์)
