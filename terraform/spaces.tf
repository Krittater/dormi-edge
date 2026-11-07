# ที่เก็บ dump ฐานข้อมูลรายวัน (DigitalOcean Spaces = ที่เก็บไฟล์แบบ S3) — อยู่นอก droplet
# droplet พังหรือถูกลบ dump ก็ยังอยู่ · สคริปต์ที่อัปขึ้นมา: deploy/backup/db-dump-to-spaces.sh
#
# ★ ค่าใช้จ่าย Spaces เหมาจ่าย ~$5/เดือน (รวม 250GB) ไม่ขึ้นกับจำนวน bucket
# ★ provider ต้องใช้ Spaces key (คนละตัวกับ token) จาก env:
#     SPACES_ACCESS_KEY_ID / SPACES_SECRET_ACCESS_KEY
resource "digitalocean_spaces_bucket" "db_backups" {
  name   = "dormi-db-backups" # ชื่อต้องไม่ซ้ำใครทั้ง region
  region = "sgp1"             # ที่เดียวกับ droplet — อัปเร็ว ไม่มีค่าโอนข้ามที่
  acl    = "private"          # ★ ห้ามเปิด public — ข้างในคือข้อมูลลูกค้าทั้งหมด

  # DigitalOcean ลบไฟล์ที่เก่ากว่า 14 วันให้เอง — สคริปต์ไม่ต้องลบเอง
  lifecycle_rule {
    enabled = true
    expiration {
      days = 14
    }
  }

  lifecycle {
    prevent_destroy = true # กันลบ bucket (พร้อม backup ทั้งหมด) ด้วยความเผลอ
  }
}
