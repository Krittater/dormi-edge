# snapshot ทั้งเครื่อง ก่อน resize — ถ้า resize มีปัญหา กู้ทั้งเครื่องกลับจาก snapshot นี้ได้
#
# ★ ถ่ายตอนเครื่องเปิดอยู่ (เว็บไม่ล่ม) — ข้อมูลฐานข้อมูลอาจไม่ตรงกันเป๊ะถ้ามีคนเขียนอยู่พอดี
#   จึง pg_dump ลงเครื่องตัวเองไว้ก่อนทุกครั้ง (Private\dormi-backups\)
# ★ snapshot คิดเงินตามขนาด (~$0.06/GB/เดือน) — resize ผ่านแล้วไม่ใช้ = ลบ block นี้ แล้ว apply
resource "digitalocean_droplet_snapshot" "before_resize" {
  droplet_id = digitalocean_droplet.dormi.id
  name       = "dormi-before-resize-2026-10"
}
