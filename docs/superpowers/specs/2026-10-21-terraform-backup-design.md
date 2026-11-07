# Terraform (DigitalOcean) — backup ขั้นต่ำ · design

ตกลงกับผู้ใช้ 2026-10-21 · repo `dormi-edge` · ทดสอบ restore เป็นงานวันอื่น (นอกขอบเขต)

## เป้าหมาย

ใช้ Terraform จัดการ droplet production ให้ **backup ได้** ก่อน resize — **เล็กและอ่านเข้าใจง่าย** (ผู้ใช้จะใช้ศึกษา Terraform)

## ข้อเท็จจริงของ droplet (อ่านจาก metadata 2026-10-21)

| | ค่า |
|---|---|
| id | `582380740` |
| name / hostname | `dormi-linkandrent` |
| region | `sgp1` |
| size | `s-1vcpu-2gb` |
| ipv6 | ปิด |
| monitoring (`do-agent`) | เปิด |
| VPC | มี (private interface) |
| ssh keys | 1 |
| reserved IP / tags | ไม่มี |
| OS | Ubuntu 24.04.4 LTS |

## สิ่งที่ตัดสินใจแล้ว

| # | ตัดสินใจ |
|---|---|
| D1 | โฟลเดอร์ `dormi-edge/terraform/` · state เก็บ local (gitignored) · ยังไม่ทำ remote backend |
| D2 | **import** droplet เดิม — ห้ามสร้างใหม่/ลบ (`prevent_destroy`) |
| D3 | เปิด **DO Backups** รายสัปดาห์ผ่าน `backups = true` (+ `backup_policy` ถ้า provider รองรับ) |
| D4 | **snapshot ก่อน resize** เป็น resource `digitalocean_droplet_snapshot` หนึ่งตัว — เลิกใช้ = ลบ block แล้ว apply |
| D5 | `resize_disk = false` ตั้งแต่วันแรก — resize ภายหลังต้องเป็นแบบ CPU/RAM เท่านั้น (ย้อนกลับได้) |
| D6 | token จาก env `DIGITALOCEAN_TOKEN` เท่านั้น — ห้ามอยู่ในไฟล์/แชท · คำสั่งที่ต้องใช้ token ผู้ใช้รันเองใน terminal ของตัวเอง |
| D7 | เอกสารภาษาไทย (README) อธิบายแต่ละไฟล์และคำสั่ง สำหรับศึกษา |
| D8 | **`pg_dump` ฐานข้อมูลทุกวัน ขึ้น DO Spaces เก็บ 14 วัน** (เพิ่ม 2026-10-21) — DO Backups ตั้งเก็บ 14 วันไม่ได้ (daily = 7 วันตายตัว) จึงคง DO Backups รายสัปดาห์ไว้ (ทั้งเครื่อง 4 สัปดาห์) + dump รายวันนอกเครื่อง |
| D9 | bucket สร้างด้วย Terraform (`private` + lifecycle ลบไฟล์เก่ากว่า **14 วัน** เอง) · ไม่เขียนโค้ดลบไฟล์เก่าเอง |
| D10 | dump รันบน server ด้วย cron **03:30 เวลาไทย (20:30 UTC)** — ห่างจาก scheduler ออกบิลตี 1 · อัปด้วย `curl --aws-sigv4` ที่มีอยู่แล้ว (ไม่ติดตั้งอะไรเพิ่ม) · เก็บสำเนาในเครื่อง 3 วันล่าสุดเผื่อ Spaces ล่ม |
| D11 | key ของ Spaces: Terraform (เครื่องผู้ใช้) ใช้ key เต็มสิทธิ์จาก env · server ใช้ **key จำกัดสิทธิ์เฉพาะ bucket นี้** เก็บใน `/root/.config/dormi-db-backup.env` (chmod 600) — ไม่อยู่ใน repo |
| D12 | dump ล้ม = exit ≠ 0 + บรรทัด `FAILED` ใน log · สำเร็จ = อัปเดตไฟล์ `last-success` (ให้ monitoring มาอ่านทีหลัง) |

## นอกขอบเขต

resize จริง · ทดสอบ restore · import DNS/firewall · CI สำหรับ Terraform · แจ้งเตือนเมื่อ dump ล้ม (ทำกับ monitoring ทีหลัง)
