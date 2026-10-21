# Terraform — backup ของ Dormi (DigitalOcean)

ชุดเล็กที่สุดที่ใช้งานได้จริง: **ดูแล droplet production + เปิด backup + snapshot + ที่เก็บ dump รายวัน**
ไม่มี module ไม่มีตัวแปร — อ่านไฟล์ `.tf` ทีละไฟล์ก็เข้าใจทั้งหมด

## Terraform คืออะไร (สั้น ๆ)

- เขียนลงไฟล์ว่า **อยากให้ของบน DigitalOcean เป็นแบบไหน** → Terraform เทียบกับของจริง → ทำให้ตรง
- **state** (`terraform.tfstate`) = สมุดที่ Terraform จดว่าดูแลอะไรอยู่ · อยู่เครื่องนี้เครื่องเดียว · **ห้ามลบ ห้าม commit**
- **import** = รับของที่มีอยู่แล้วมาดูแล แทนการสร้างใหม่ (droplet ของเราใช้วิธีนี้)

## ไฟล์ในโฟลเดอร์นี้

| ไฟล์ | หน้าที่ |
|---|---|
| `versions.tf` | ใช้ provider DigitalOcean รุ่น 2.x · token/key อ่านจาก env |
| `droplet.tf` | เครื่อง production: ขนาด, backup รายสัปดาห์, กันลบ, ห้ามขยายดิสก์ตอน resize |
| `snapshot.tf` | snapshot ทั้งเครื่องก่อน resize |
| `spaces.tf` | bucket `dormi-db-backups` (private) ลบไฟล์เก่ากว่า 14 วันเอง |
| `.terraform.lock.hcl` | ล็อกรุ่น provider — commit |
| `.gitignore` | กัน state / ไฟล์ลับ ไม่ให้หลุดเข้า git |

สคริปต์ dump รายวันที่รันบน server อยู่ที่ `../deploy/backup/` (ไม่ใช่ Terraform)

## เริ่มใช้ (ทุกครั้งที่เปิด PowerShell ใหม่)

```powershell
cd C:\Users\Anuchit\Desktop\Private\dormi\dormi-edge\terraform

# DO token (สร้างที่ DO → API → Tokens) — พิมพ์แล้วขึ้น **** ไม่โชว์ค่าจริง
$s = Read-Host "DO token" -AsSecureString; $env:DIGITALOCEAN_TOKEN = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)); Remove-Variable s

# Spaces key (DO → Spaces Object Storage → แท็บ Access Keys → Create Access Key · Full access) — ใช้กับ spaces.tf
$a = Read-Host "Spaces Access Key" -AsSecureString; $env:SPACES_ACCESS_KEY_ID = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($a)); $b = Read-Host "Spaces Secret Key" -AsSecureString; $env:SPACES_SECRET_ACCESS_KEY = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($b)); Remove-Variable a, b
```

ครั้งแรกบนเครื่องใหม่: `terraform init` (ดาวน์โหลด provider)

## 3 คำสั่งที่ใช้

| คำสั่ง | ทำอะไร |
|---|---|
| `terraform plan` | **ดูก่อน** ว่าจะเปลี่ยนอะไร — ไม่แตะของจริง |
| `terraform apply` | แสดง plan อีกรอบ → พิมพ์ `yes` → ลงมือจริง |
| `terraform state show <ชื่อ>` | ดูค่าที่ Terraform จำไว้ เช่น `digitalocean_droplet.dormi` |

### อ่านผล plan

| เห็น | แปลว่า | ทำต่อ |
|---|---|---|
| `+ create` | สร้างใหม่ | ✅ ถ้าตั้งใจ |
| `~ update in-place` | แก้ของเดิม เครื่องเดิมยังอยู่ | ✅ **ถ้าเป็นค่าที่ตั้งใจแก้** — อ่านทุกบรรทัดที่มี `~` |
| `- destroy` | ลบ | ⚠️ ดูให้ชัดว่าลบอะไร |
| **`-/+ must be replaced`** | **ลบเครื่องแล้วสร้างใหม่** | ❌ **ห้าม apply** |

กันพลาดไว้แล้ว: droplet และ bucket มี `prevent_destroy` — สั่งลบจะโดนปฏิเสธ (`Instance cannot be destroyed`)

> ⚠️ **apply เฉพาะสิ่งที่ตั้งใจเปลี่ยนเท่านั้น** — ถ้า plan มี `~ size` ของ droplet ที่คุณไม่ได้แก้ (เช่น เคย resize ผ่าน dashboard แล้วไฟล์ยังเป็นขนาดเก่า) apply = **เครื่องถูกปิดและถูกลดขนาดกลับ** · แก้ไฟล์ให้ตรงของจริงก่อน
>
> ⚠️ **`prevent_destroy` คุ้มครองเฉพาะตอน block ยังอยู่ในไฟล์** — ลบ block ของ droplet หรือ bucket ทิ้งแล้ว apply = **ลบเครื่อง/ลบ backup จริง** · อยากเลิกให้ Terraform ดูแลโดยไม่ลบของจริง ใช้ block ด้านล่างแทนการลบ (หรือ `terraform state rm`)

```hcl
removed {
  from = digitalocean_droplet.dormi
  lifecycle {
    destroy = false # เลิกดูแลเฉย ๆ เครื่องจริงยังอยู่
  }
}
```

## งานที่ทำบ่อย

### resize เครื่อง

1. `droplet.tf` → แก้ `size` เช่น `"s-2vcpu-4gb"`
2. `terraform plan` → ต้องขึ้น **`update in-place`** (ห้ามเป็น `must be replaced`)
3. `terraform apply` → เครื่องปิด-เปิดเอง **ราว 2–5 นาที** เว็บล่มช่วงนั้น container ทุกตัวขึ้นเอง (`restart: always`)
4. `resize_disk = false` = เปลี่ยนแค่ CPU/RAM → **ลดกลับได้** · หลีกเลี่ยงช่วงตี 1 (scheduler ออกบิล)

### ลบ snapshot หลัง resize ผ่าน

ลบ block ใน `snapshot.tf` (หรือลบทั้งไฟล์) → `terraform plan` ต้องขึ้น `1 to destroy` ที่เป็น **snapshot เท่านั้น ไม่มีอย่างอื่น** → `apply`

★ วิธี "ลบ block แล้ว apply" ใช้ได้กับ **snapshot เท่านั้น** — ห้ามใช้กับ `droplet.tf` / `spaces.tf` (ดูคำเตือนด้านบน)

### ดู backup ว่ามีจริง

| ชั้น | ดูที่ |
|---|---|
| DO Backups (ทั้งเครื่อง รายสัปดาห์ เก็บ 4 ชุด) | DO dashboard → Droplets → `dormi-linkandrent` → **Backups** |
| Snapshot | DO dashboard → **Backups & Snapshots → Snapshots** |
| dump รายวัน (ฐานข้อมูล เก็บ 14 วัน) | DO dashboard → **Spaces** → `dormi-db-backups` → โฟลเดอร์ `daily/` |
| รอบล่าสุดของ dump รายวัน | บน server: `tail /var/log/dormi-db-backup.log` · `cat /var/backups/dormi/last-success` |

## ยังไม่ครอบคลุม

- **ทดสอบกู้คืน (restore)** — ต้องทำสักครั้ง backup ที่ไม่เคยลองกู้ = ยังไม่รู้ว่าใช้ได้
- **แจ้งเตือนเมื่อ dump รายวันล้ม** — ตอนนี้ดูได้จาก log / `last-success` เท่านั้น
- DNS, firewall ยังไม่ได้อยู่ใน Terraform
