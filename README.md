# Dormi Edge (reverse proxy ด่านหน้าสุด)

Nginx edge รับ traffic 80/443 → terminate TLS → route ตาม Host → **load balance เอง**
ไปยัง service บน `dormi_network` (ไม่แตะ DB ตรงๆ) จัดการใบรับรอง TLS อัตโนมัติทั้งวงจรด้วย certbot
โครงนี้ยึด pattern จาก `nst-nginx-front`

```
internet → :80/:443 → edge (ตัวนี้) ──→ dormi-api:3000   (backend)
                                    ──→ dormi-web:3000   (frontend)
                                    ──→ dormi-admin:3000 (admin — ยังไม่มี)
```

## โครงไฟล์

| Path | หน้าที่ |
|------|--------|
| `Dockerfile` | nginx:1.28-alpine + openssl + inotify-tools + entrypoint scripts |
| `docker-compose.yml` | service `edge` + `certbot` (network `dormi_network`) |
| `docker-compose.dev.yml` | override สำหรับ dev (ไม่รัน certbot, ใช้ dummy cert) |
| `docker-entrypoint.d/10-init-dummy-cert.sh` | สร้าง cert ปลอมตอน boot แรก (nginx start ได้ก่อนมี cert จริง) |
| `docker-entrypoint.d/20-reload-nginx-on-cert-change.sh` | เฝ้าไฟล์ cert → reload nginx อัตโนมัติเมื่อต่ออายุ |
| `nginx/nginx.conf` | main: tuning + JSON log + TLS + gzip + default guards + include projects |
| `nginx/snippets/proxy_common.conf` | header/timeout มาตรฐานของ reverse proxy (include ต่อ location) |
| `nginx/projects/10-dormi.conf` | vhost: dormi API (`dormi-api.`) |
| `nginx/projects/20-admin-api.conf` | vhost: admin API (`admin-api.`) |
| `nginx/projects/30-web.conf` | vhost: หน้าเว็บ (apex `dormi-linkandrent.com`) |
| `nginx/projects/_new-project.conf.example` | **template** สำหรับเพิ่ม project ใหม่ (nginx ไม่โหลด `.example`) |
| `nginx/projects/_web-frontend.conf.example` | **template** ของ web vhost (ตัวใช้จริงคือ 30-web.conf) |
| `scripts/issue-cert.sh` | ออก/ต่ออายุ cert — รวมทุกโดเมนจาก `projects/*.conf` อัตโนมัติ |
| `data/certbot/` | cert + ACME webroot (แชร์ edge↔certbot · **gitignored**) |
| `.env` | `CERTBOT_EMAIL=<อีเมลจริง>` (**gitignored** — สร้างเองบน server) |

## Routing ปัจจุบัน

| โดเมน | → upstream (docker service) | สถานะ |
|-------|-----------|-------|
| `dormi-linkandrent.com` (apex) | `dormi-web:3000` | ✅ live (frontend Node server) |
| `dormi-api.dormi-linkandrent.com` | `dormi-api:3000` | ✅ live (backend API) |
| `admin-api.dormi-linkandrent.com` | `dormi-admin:3000` | ⚠️ 502 จนกว่าจะมี service `dormi-admin` |
| host อื่น / IP scan | — | ตัดทิ้ง (444 / reject TLS handshake) |

TLS ใช้ **SAN cert ใบเดียว** ชื่อ `edge-dormi` ครอบทุกโดเมนข้างบน · ต่ออายุอัตโนมัติทุก 12 ชม.

---

## 🚀 Deploy ขึ้น Production (ทีละขั้น — ทำตามได้เลย)

> **หลักการสำคัญ:** ห้ามแก้ config บน server — แก้ที่เครื่องเรา → push GitHub → pull บน server → reload
>
> สัญลักษณ์: 💻 = ทำที่เครื่องเรา · 🖥️ = ทำบน server (ssh เข้าไปแล้ว)

### สิ่งที่ต้องมีก่อน (ทำครั้งเดียว)

1. **backend deploy แล้ว** (repo `dormi-backend-2` — ดู README ที่นั่น) เพราะ edge จะ proxy ไปหามัน
2. **DNS** (ตั้งที่ Namecheap): A record ทุกโดเมนใน `nginx/projects/*.conf` ชี้ไป IP ของ server
   - `dormi-api` → `<SERVER_IP>`
   - `admin-api` → `<SERVER_IP>`
   - `@` (apex) → `<SERVER_IP>`
   ตรวจว่า DNS มาแล้ว: `nslookup dormi-api.dormi-linkandrent.com` ต้องได้ IP server
3. **Firewall** (DigitalOcean): เปิด inbound **80 + 443** (⚠️ ลืม 80 = ออก cert ไม่ได้ เพราะ Let's Encrypt ตรวจผ่าน port 80)

### ขั้นตอน deploy ครั้งแรก

**1) 💻 push โค้ดขึ้น GitHub** (`git push origin main`)

**2) 🖥️ clone + สร้างไฟล์ .env**

```bash
cd ~ && git clone https://github.com/Krittater/dormi-edge.git
cd dormi-edge
echo "CERTBOT_EMAIL=อีเมลจริงของเรา@gmail.com" > .env
```

> อีเมลนี้ Let's Encrypt ใช้เตือนก่อน cert หมดอายุ — ใส่อีเมลจริงที่เช็คบ่อย

**3) 🖥️ สร้าง network (ถ้ายังไม่มี) + start edge**

```bash
docker network create dormi_network 2>/dev/null; true
docker compose up -d --build
```

ตอนนี้ edge จะ start ด้วย **dummy cert** (สร้างเองอัตโนมัติ) — เข้าเว็บได้แต่เบราว์เซอร์เตือน cert = ปกติ ยังไม่จบ

**4) 🖥️ ออก cert จริง**

```bash
set -a && . ./.env && set +a
sh scripts/issue-cert.sh
```

สคริปต์จะรวมโดเมนจากทุกไฟล์ `projects/*.conf` ให้อัตโนมัติ → certbot ตรวจสอบผ่าน port 80 →
ได้ cert จริง → nginx **reload เอง** (inotify เฝ้าไฟล์อยู่) ไม่ต้องทำอะไรต่อ

**5) 🖥️ + 💻 ตรวจ**

```bash
# บน server
docker exec dormi-edge nginx -t                        # syntax ok
openssl x509 -in data/certbot/conf/live/edge-dormi/fullchain.pem -noout -issuer -ext subjectAltName
# issuer ต้องเป็น Let's Encrypt + SAN ครบทุกโดเมน

# จากเครื่องเรา (ผ่าน internet จริง)
curl https://dormi-api.dormi-linkandrent.com/whoami    # ได้ "dormi-api" ไม่มี cert เตือน
curl https://dormi-linkandrent.com/whoami              # ได้ "dormi-web"
```

### เมื่อแก้ config (รอบถัดไป)

```
💻 แก้ไฟล์ใน nginx/ → commit → git push origin main
🖥️ cd ~/dormi-edge && git pull origin main
🖥️ docker exec dormi-edge nginx -t && docker exec dormi-edge nginx -s reload
```

> config ถูก mount เข้า container — pull แล้ว reload ได้เลย **ไม่ต้อง rebuild**
> (rebuild เฉพาะเมื่อแก้ Dockerfile / entrypoint scripts: `docker compose up -d --build`)

---

## ⚠️ กติกา cert ที่ต้องจำ

- cert เป็น **SAN ใบเดียว all-or-nothing** — ทุกโดเมนใน `projects/*.conf` ต้องชี้ DNS มาที่
  server นี้ + port 80 เข้าถึงได้ **ทุกตัว** ไม่งั้น cert fail ทั้งใบ
- โดเมนไหนยังไม่พร้อม (DNS ยังไม่ชี้) → **อย่าเพิ่งใส่ใน `.conf`** หรือ park ไฟล์เป็น `.example` ก่อน
- ออก cert ใหม่เมื่อ: เพิ่ม/ลบโดเมน (`sh scripts/issue-cert.sh` ใหม่) — ต่ออายุปกติ certbot ทำเองทุก 12 ชม.
- ห้าม commit `data/`, `*.pem`, `*.key`, `.env` (มี .gitignore กันแล้ว)

## Load balancing (edge = LB ในตัว)

แต่ละ vhost มี `upstream <x>_pool { least_conn; server <service>:<port> resolve; }`
`resolve` ดึง IP ของทุก replica จาก docker DNS อัตโนมัติ → **scale โดยไม่ต้องแก้ config**:

```bash
# ที่ repo ของ service นั้น (backend/frontend)
docker compose up -d --scale dormi-api=4    # edge เห็น replica ใหม่เองใน ~10 วิ
```

## เพิ่ม project/โดเมนใหม่ (3 ขั้น)

1. 💻 copy template → สร้างไฟล์จริง (ปล่อยไฟล์ `.example` ไว้เป็น template เสมอ):
   ```bash
   cp nginx/projects/_new-project.conf.example nginx/projects/40-<project>.conf
   ```
   แก้ 3 จุด: `<project>` (ชื่อ pool), `<domain>` (server_name), `<service>:<port>` (upstream)
   → commit + push → 🖥️ pull
2. ตั้ง DNS โดเมนใหม่ → IP server แล้วออก cert ใหม่: 🖥️ `sh scripts/issue-cert.sh`
3. 🖥️ reload: `docker exec dormi-edge nginx -t && docker exec dormi-edge nginx -s reload`

## Dev บนเครื่องตัวเอง

```bash
docker network create dormi_network   # ครั้งเดียว
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d --build
# ใช้ dummy cert (เบราว์เซอร์เตือน = ปกติ) · ไม่รัน certbot
```
