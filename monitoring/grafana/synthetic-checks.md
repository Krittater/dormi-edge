# Synthetic checks — ตรวจเว็บ/API จากภายนอก (สร้างเองใน UI)

Grafana Synthetic Monitoring ส่งคำขอ HTTP เข้าเว็บเราจากภายนอกทุก 5 นาที (ค่าที่ใช้จริงบน prod ตั้งแต่ 2026-10-24) แล้วเก็บผลเป็น metric (`probe_success`, `probe_ssl_earliest_cert_expiry`, `probe_duration_seconds`)
dashboard "Dormi ภาพรวม" และ alert **เว็บ/API ล่ม** / **cert ใกล้หมด** อ่านจาก metric นี้

**ทำไมสร้างมือ:** API ของ Synthetic ต้องใช้ token แยกอีกตัว — ระยะแรกไม่ทำ automation (ตกลงไว้ใน decisions.md) · ทำครั้งเดียว ประมาณ 10 นาที

## วิธีสร้าง (ทำก่อนนำเข้า alert — ขั้น H1 เสร็จแล้ว)

1. Grafana Cloud → เมนู **Testing & synthetics → Synthetics** → ถ้าถามให้กด **Initialize** (ฟรี ไม่ต้องใส่บัตร)
2. กด **Add new check** → ชนิด **HTTP** → กรอกตามตารางด้านล่าง ทีละ check (4 ครั้ง)
3. ตั้งค่าเหมือนกันทุก check:

| ช่อง | ค่า |
|---|---|
| Frequency (ความถี่) | **5 minutes** (300s — UI สร้างเป็นชนิด MULTIHTTP ก็ใช้ได้) |
| Probe locations | **เลือก 1 จุดเดียว: Singapore** (ใกล้ไทยที่สุด — ถ้ารายการของคุณไม่มี ให้เลือก Tokyo หรือ Mumbai) |
| Request method | GET |
| Timeout | 10 วินาที |
| Valid status codes | ค่าเริ่มต้น (2xx) |
| Follow redirects | เปิด (ค่าเริ่มต้น) |
| SSL: fail if SSL not present | **เปิด** (ทำให้วัดวันหมดอายุ cert ได้) |
| Alerting (ของ Synthetic เอง) | **ปิด/None** — เราใช้ alert ของ Dormi ในโฟลเดอร์ Dormi แทน (กันเตือนซ้ำสองทาง) |
| Custom labels | ไม่ต้องใส่ |

## 4 checks

| # | ชื่อ (Job name) | Target (URL — พิมพ์ให้ตรงตามนี้ทุกตัวอักษร) | ตรวจอะไร |
|---|---|---|---|
| 1 | `dormi-web` | `https://app.dormi-linkandrent.com/login` | หน้าเว็บที่ลูกค้าใช้ (ห้ามใช้ `/` — ตอบ 307 ไป /dashboard และ probe ไม่ตาม redirect = นับว่าล่มตลอด) |
| 2 | `dormi-api-version` | `https://dormi-api.dormi-linkandrent.com/version` | API หลัก (backend) |
| 3 | `dormi-admin-health` | `https://admin-api.dormi-linkandrent.com/health` | API ของ admin |
| 4 | `dormi-landing` | `https://dormi-linkandrent.com/` | หน้าแรก (landing) |

> check #4 (apex) ต้องการ cert จริง — ตอนนี้ apex ใช้ Let's Encrypt จริงแล้ว (cutover landing เสร็จ 2026-10-24) จึงสร้างได้ทันที ไม่มีขั้นตอนรอ

## กฎสำคัญ (ถ้าผิด alert จะเงียบหรือเตือนผิด)

- **Target ต้องเป็น URL เต็มตามตาราง** — dashboard/alert จับด้วย label `instance` = URL นี้ (ตรงชื่อโดเมน `app.` / `dormi-api.` / `admin-api.` / apex)
- **ห้ามตั้ง Job name เป็น `dormi-app`** — ชื่อนั้นเป็น job ของตัวเก็บ metric จากแอป จะปนกัน (ใช้ชื่อตามตารางได้เลย)
- เพิ่ม/ลบ check เป็น 5 ตัวหรือ 3 ตัว: ไม่ต้องแก้ alert ถ้า URL อยู่ใต้ 4 โดเมนข้างต้น · ถ้าเป็นโดเมนอื่นต้องแก้ regex ใน `alerts/dormi-alerts.yaml` และ dashboard

## ตรวจว่าถูกต้อง (หลังสร้าง ~5 นาที)

1. Grafana → Explore → เลือก datasource ชนิด Prometheus (`grafanacloud-…-prom`) → รัน `probe_success` → ต้องเห็น 4 บรรทัด ค่า `1`
2. dashboard "Dormi ภาพรวม" แถวแรก ต้องขึ้น 4 ช่อง "ปกติ" สีเขียว และ "cert เหลือกี่วัน" มีตัวเลข

## โควตาฟรี

4 checks × ทุก 5 นาที × 1 จุด ≈ 35,000 ครั้ง/เดือน (ชั้นฟรีของ Grafana Cloud ให้ราว 100,000 ครั้ง/เดือน — ตรวจตัวเลขล่าสุดที่หน้า Usage)
**ห้ามเพิ่มจุดตรวจ (probe) หรือถี่ขึ้น** — จะเกินโควตาฟรี (ข้อกำหนด: ค่าใช้จ่าย 0 บาท)
