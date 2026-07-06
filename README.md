# Dormi Edge (reverse proxy ด่านหน้าสุด)

Nginx edge รับ traffic 80/443 → terminate TLS → route ตาม Host → **load balance เอง**
ไปยัง API pool บน `dormi_network` (ไม่แตะ DB ตรงๆ) จัดการใบรับรอง TLS อัตโนมัติทั้งวงจรด้วย certbot
โครงนี้ยึด pattern จาก `nst-nginx-front`

## โครงไฟล์

| Path | หน้าที่ |
|------|--------|
| `Dockerfile` | nginx:1.28-alpine + openssl + inotify-tools + entrypoint scripts |
| `docker-compose.yml` | service `edge` + `certbot` (network `dormi_network`) |
| `docker-compose.dev.yml` | override สำหรับ dev (ไม่รัน certbot, ใช้ dummy cert) |
| `docker-entrypoint.d/10-init-dummy-cert.sh` | สร้าง cert ปลอมตอน boot แรก (nginx start ก่อนมี cert จริง) |
| `docker-entrypoint.d/20-reload-nginx-on-cert-change.sh` | เฝ้าไฟล์ cert → reload nginx อัตโนมัติเมื่อต่ออายุ |
| `nginx/nginx.conf` | main: tuning + JSON log + TLS + gzip + default guards + include projects |
| `nginx/snippets/proxy_common.conf` | header/timeout มาตรฐานของ reverse proxy (include ต่อ location) |
| `nginx/projects/10-dormi.conf` | vhost: dormi API (`dormi-api.`) |
| `nginx/projects/20-admin-api.conf` | vhost: admin API (`admin-api.`) |
| `nginx/projects/_web-frontend.conf.example` | (park) frontend vhost เผื่อเสิร์ฟผ่าน edge |
| `data/certbot/` | cert + ACME webroot (แชร์ edge↔certbot · **gitignored**) |

## Routing (ปรับโดเมน/upstream ให้ตรงจริงก่อน deploy)

| โดเมน | → upstream (docker service) | สถานะ |
|-------|-----------|-------|
| `dormi-api.dormi-linkandrent.com` | `dormi-api:3000` | ✅ พร้อม (service มีใน backend) |
| `admin-api.dormi-linkandrent.com` | `dormi-admin:3000` | ⚠️ 502 จนกว่าจะมี service `dormi-admin` |
| host อื่น / IP scan | — | ตัดทิ้ง (444 / reject handshake) |

TLS ใช้ SAN cert `edge-dormi` ใบเดียวครอบทุกโดเมนข้างบน

## รัน

**Dev (localhost, dummy self-signed cert):**
```bash
docker network create dormi_network   # ทำครั้งเดียว
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
```

**Production:**
```bash
docker network create dormi_network
docker compose up -d --build
# ออก cert จริงครั้งแรก (dummy จะถูกแทน, nginx reload เอง):
# แนะนำ: ใช้ scripts/issue-cert.sh (รวมโดเมนจาก projects/*.conf ให้อัตโนมัติ)
sh scripts/issue-cert.sh
# หรือระบุเอง:
docker compose run --rm certbot certbot certonly --webroot -w /var/www/certbot \
  --cert-name edge-dormi \
  -d dormi-api.dormi-linkandrent.com -d admin-api.dormi-linkandrent.com \
  --email admin@dormi-linkandrent.com --agree-tos --no-eff-email
```

> ⚠️ cert เป็น SAN ใบเดียว (all-or-nothing) — ทุกโดเมนใน `projects/*.conf` ต้องชี้ DNS
> มาที่ edge + เข้าถึง port 80 ได้ ไม่งั้นออก cert ไม่ผ่าน ถ้า `admin-api` DNS ยังไม่พร้อม
> ให้ park `20-admin-api.conf` เป็น `.example` ก่อน แล้วออก cert เฉพาะ `dormi-api`

## ตรวจ

```bash
docker exec dormi-edge nginx -t
curl -k https://dormi-api.dormi-linkandrent.com/whoami   # ควรได้ "dormi-api"
```

> ⚠️ อย่า commit `data/` หรือไฟล์ `*.pem`/`*.key`/`*.crt` (มี .gitignore กันไว้แล้ว)

## Load balancing (edge = LB ในตัว)

แต่ละ vhost มี `upstream <x>_pool { least_conn; server <service>:<port> resolve; }`
`resolve` ดึง IP ของทุก replica จาก docker DNS อัตโนมัติ → **scale โดยไม่ต้องแก้ config**:

```bash
docker compose up -d --scale dormi-api=4     # edge กระจาย load ให้ 4 replica เอง
```

## เพิ่ม project ใหม่ (3 ขั้น — ตั้งค่าน้อย)

1. copy template → ตั้งเลขลำดับ:
   ```bash
   cp nginx/projects/_new-project.conf.example nginx/projects/30-<project>.conf
   ```
   แก้ 3 จุด: `<project>` (ชื่อ pool), `<domain>` (server_name), `<service>:<port>` (upstream)
2. ออก cert (สคริปต์รวมโดเมนของทุก project ให้อัตโนมัติ):
   ```bash
   sh scripts/issue-cert.sh
   ```
3. reload:
   ```bash
   docker exec dormi-edge nginx -t && docker exec dormi-edge nginx -s reload
   ```

> cert เป็น **SAN ใบเดียว** (`edge-dormi`) ครอบทุกโดเมน → ไม่ต้องจัดการหลายใบ
> ต่ออายุอัตโนมัติทุก 12 ชม. โดย container `dormi-certbot`
