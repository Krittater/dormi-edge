# ใช้ Terraform รุ่นไหน + ต้องใช้ provider อะไร
# provider = ปลั๊กอินที่รู้วิธีคุยกับ API ของผู้ให้บริการ (ที่นี่คือ DigitalOcean)

terraform {
  required_version = ">= 1.5.0" # ต้อง 1.5 ขึ้นไป เพราะใช้ block `import` ใน droplet.tf

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0" # รับทุกรุ่น 2.x · รุ่นที่ใช้จริงถูกล็อกไว้ใน .terraform.lock.hcl
    }
  }
}

# ★ ไม่ใส่ token ในไฟล์นี้ — provider อ่านจาก env DIGITALOCEAN_TOKEN เอง
#   PowerShell:  $env:DIGITALOCEAN_TOKEN = "<token>"
provider "digitalocean" {}
