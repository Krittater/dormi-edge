# แจ้งเตือนของ DigitalOcean (ฟรี) — ตัวกันเหนียวที่ "ไม่พึ่ง" Grafana
# ------------------------------------------------------------
# ถ้า Alloy / Grafana Cloud พัง alert ของ Grafana จะเงียบไปด้วย — DO วัดจาก do-agent ที่ติดตั้งในเครื่องเอง
# (droplet.tf: monitoring = false เป็นแค่ flag ที่ DO บันทึก ไม่ได้ปิด do-agent) จึงยังเตือนได้แม้ monitoring ชุดใหม่ล่ม
#
# 3 ตัว: ดิสก์ > 85% · RAM > 90% · CPU > 90% (ต่อเนื่อง 10 นาที) → ส่งอีเมลตาม var.alert_emails
#
# ★ ไม่ใส่อีเมลในไฟล์ (ไม่มีค่า default) — ส่งตอนรัน อย่างใดอย่างหนึ่ง:
#     (1) สร้าง terraform.tfvars (ถูก .gitignore กันไว้แล้ว):   alert_emails = ["ชื่อ@บริษัท.com"]
#     (2) terraform plan -var 'alert_emails=["ชื่อ@บริษัท.com"]'   (bash)
# ★ ดู plan ก่อนเสมอ: ต้องเห็น "3 to add, 0 to change, 0 to destroy" เท่านั้น แล้วค่อย apply (ขั้น H7 — ผู้บริหารอนุมัติ)

variable "alert_emails" {
  type        = list(string)
  description = "อีเมลผู้รับแจ้งเตือนของ DigitalOcean (ดิสก์/RAM/CPU) — ไม่มีค่า default ตั้งใจให้ส่งตอนรัน"

  validation {
    condition     = length(var.alert_emails) > 0 && alltrue([for e in var.alert_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "alert_emails ต้องมีอย่างน้อย 1 อีเมล และรูปแบบอีเมลถูกต้อง"
  }
}

resource "digitalocean_monitor_alert" "disk_high" {
  description = "Dormi: ดิสก์ใช้เกิน 85%"
  type        = "v1/insights/droplet/disk_utilization_percent"
  compare     = "GreaterThan"
  value       = 85
  window      = "10m"
  enabled     = true
  entities    = [digitalocean_droplet.dormi.id]

  alerts {
    email = var.alert_emails
  }
}

resource "digitalocean_monitor_alert" "memory_high" {
  description = "Dormi: RAM ใช้เกิน 90% ต่อเนื่อง 10 นาที"
  type        = "v1/insights/droplet/memory_utilization_percent"
  compare     = "GreaterThan"
  value       = 90
  window      = "10m"
  enabled     = true
  entities    = [digitalocean_droplet.dormi.id]

  alerts {
    email = var.alert_emails
  }
}

resource "digitalocean_monitor_alert" "cpu_high" {
  description = "Dormi: CPU ใช้เกิน 90% ต่อเนื่อง 10 นาที"
  type        = "v1/insights/droplet/cpu"
  compare     = "GreaterThan"
  value       = 90
  window      = "10m"
  enabled     = true
  entities    = [digitalocean_droplet.dormi.id]

  alerts {
    email = var.alert_emails
  }
}
