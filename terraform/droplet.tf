# เครื่อง production ของ Dormi (droplet เดิม — ไม่ได้สร้างด้วย Terraform)
#
# import = บอก Terraform ว่า "เครื่องนี้มีอยู่แล้ว ให้รับมาดูแล" แทนที่จะสร้างใหม่
# รันครั้งแรกแล้วเครื่องจะถูกจำไว้ใน state · block นี้ทิ้งไว้ได้ ไม่มีผลรอบถัดไป
import {
  to = digitalocean_droplet.dormi
  id = "582380740"
}

resource "digitalocean_droplet" "dormi" {
  name   = "dormi-linkandrent"
  region = "sgp1"
  size   = "s-1vcpu-2gb" # resize: แก้ตรงนี้ เช่น "s-2vcpu-4gb" (ดู README)
  image  = "ubuntu-24-04-x64"
  ipv6   = false
  # ★ ต้องตรงกับที่ DO บันทึกไว้ (false) — แก้ค่านี้บังคับให้สร้างเครื่องใหม่
  #   do-agent ถูกติดตั้งแยกในเครื่องเองและยังทำงานอยู่ ค่านี้ไม่ได้ปิดมัน
  monitoring = false

  # ── backup อัตโนมัติของ DigitalOcean ──
  backups = true
  backup_policy {
    plan    = "weekly"
    weekday = "SUN"
    hour    = 20 # UTC → เริ่มตี 3 วันจันทร์เวลาไทย (ห่างจาก scheduler ออกบิลตอนตี 1)
  }

  # ★ resize ให้เปลี่ยนแค่ CPU/RAM — ถ้าเป็น true ดิสก์จะขยายด้วยและลดกลับไม่ได้อีกเลย
  resize_disk = false
  # ตอน resize ให้สั่ง OS ปิดเครื่องดี ๆ ก่อน (Postgres ได้ปิดตัวเองสะอาด) แทนการตัดไฟ
  graceful_shutdown = true

  lifecycle {
    # กัน `terraform destroy` หรือ config ผิดแล้วลบเครื่องจริง
    prevent_destroy = true
    # field พวกนี้ถ้าต่างจากเครื่องจริง Terraform จะ "สร้างเครื่องใหม่แทน" — สั่งให้ไม่สนใจ
    # (เครื่องนี้ไม่ได้สร้างจาก config นี้ ค่าจริงจึงไม่ตรงกับที่เขียนได้เสมอ)
    ignore_changes = [image, ssh_keys, user_data]
  }
}
