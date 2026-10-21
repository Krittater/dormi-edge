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

## นอกขอบเขต

resize จริง · ทดสอบ restore · backup `pg_dump` ขึ้น Spaces · import DNS/firewall/Spaces · CI สำหรับ Terraform
