# Dormi Deploy — สถาปัตยกรรม + logic + วิธีใช้ (ฉบับละเอียด)

> เอกสารนี้ไว้ **กลับมาอ่านตอนลืม** — อ่านจบเข้าใจทั้ง "ระบบทำงานยังไง" และ "กดยังไง"
> เรื่อง nginx/TLS/cert ของ edge ดูละเอียดที่ [`../README.md`](../README.md) — ไฟล์นี้เน้น **การ deploy ทั้ง stack**

---

## 0. TL;DR (อ่าน 30 วิ)

- **edge** = nginx ด่านหน้า รับ 80/443 → route ตาม Host → proxy ไป `dormi-api` / `dormi-web` บน network `dormi_network`
- deploy มี **2 แบบ**:
  1. **per-service** (`dormi-backend/`, `dormi-frontend/`) — deploy ทีละตัว สั่งมือ ง่าย มี migration guard + self-rollback ในตัว
  2. **full-update** (`dormi-full-update/`) — deploy **ทั้ง stack พร้อมกัน** เป็นขั้นตอน + snapshot + rollback ประสานกัน + บันทึก version สั่งจาก GitHub Actions (หรือ local)
- **หลักเหล็ก:** ห้ามแก้โค้ด/config บน server — แก้ที่เครื่องเรา → push GitHub → deploy pull ลงมา
- **จุดกลับ (rollback) = image `:prev`** ที่ snapshot tag ไว้ → ถอยได้ทันทีโดยไม่ต้อง build
- **DB ปลอดภัย:** migration มี backup ก่อนเสมอ + revert DB แบบ "เปลี่ยนชื่อของเก่าเก็บไว้ ไม่ drop"

---

## 1. สถาปัตยกรรมภาพรวม

### 1.1 เส้นทาง request

```
                          ┌───────────────────────────── server (DigitalOcean 188.166.228.210) ─────────────────────────────┐
                          │                                                                                                  │
internet ── :80/:443 ───► │  dormi-edge (nginx)  ── route by Host ──►  dormi-api:3000        (docker-dormi-api-1)            │
                          │   • terminate TLS                      ──►  dormi-web:3000        (dormi-fe-2-dormi-web-1)        │
                          │   • LB (upstream resolve)              ──►  dormi-admin:3000      (ยังไม่มี → 502)               │
                          │   • default guard 444 / reject         │                                                         │
                          │                                        │    dormi-scheduler       (docker-dormi-scheduler-1)     │
                          │  dormi-certbot (renew ทุก 12 ชม.)      │      └ รัน migration + seed + cron                      │
                          │                                        │                                                         │
                          │                                             dormi_postgres:16  (127.0.0.1 เท่านั้น ไม่ออกเน็ต)  │
                          │  ─────── ทั้งหมดอยู่บน network: dormi_network (external) ───────                                │
                          └──────────────────────────────────────────────────────────────────────────────────────────────┘
```

- edge **ไม่แตะ DB** — คุยแค่ api/web ผ่าน docker DNS
- postgres **ไม่มี public port** (bind `127.0.0.1:5432` เท่านั้น) — เข้าจากนอกต้องผ่าน SSH tunnel
- `dormi_network` เป็น `external: true` → ทุก repo (edge/backend/frontend) join network ชื่อเดียวกัน

### 1.2 Container ที่รันจริง

| Container | Image | มาจาก repo | หน้าที่ |
|---|---|---|---|
| `dormi-edge` | `dormi-edge-edge` | dormi-edge | nginx reverse proxy + TLS |
| `dormi-certbot` | `certbot/certbot` | dormi-edge | ต่ออายุ cert อัตโนมัติ |
| `docker-dormi-api-1` | `docker-dormi-api` | dormi-backend-2 | REST API (`SCHEDULER_ENABLED=false`) |
| `docker-dormi-scheduler-1` | `docker-dormi-scheduler` | dormi-backend-2 | seed + cron (`SCHEDULER_ENABLED=true`) — prod **ไม่** migrate เองตอน boot, migration ทำผ่าน edge step1 เท่านั้น |
| `dormi-fe-2-dormi-web-1` | `dormi-fe-2-dormi-web` | frontend | Next.js standalone (Node server) |
| `dormi_postgres` | `postgres:16-alpine` | backend compose | ฐานข้อมูล (`user=dormi` `db=dormi_v2`) |

### 1.3 ที่อยู่ไฟล์บน server

```
/root/
├── dormi-edge/               ← repo นี้ (branch main)  — deploy scripts รันจากที่นี่
│   └── releases/             ← ★ สำเนา version log (push กลับ git โดย step4)
├── dormi-backend-2/          ← backend clone (branch master)
├── dormi-fe-2/               ← frontend clone (branch main)
└── dormi-releases/           ← ★ state ของ full-update (ตัวจริง — ไม่ใช่ git)
    ├── VERSION               ← เลข release ปัจจุบัน เช่น 0.1.4
    ├── RELEASES.log          ← ประวัติ release (append-only)
    ├── db-backups/           ← *.dump (pg_dump -Fc, เก็บ 20 ไฟล์ล่าสุด)
    └── snapshots/
        ├── latest → 2026.../ ← symlink ชี้ snapshot ล่าสุด
        └── 20260712-063831/
            ├── snapshot.env  ← จุดกลับ: image :prev tags + commit เดิม
            └── MIGRATION_RAN ← marker (มี = รอบนี้แตะ DB) + path backup
```

### 1.4 /version — หัวใจของ health check + version tracking

ทั้ง backend และ frontend มี endpoint `GET /version` คืน commit ที่ **รันอยู่จริง**:

```jsonc
// backend (ถูก ResponseInterceptor ห่อ → อยู่ใน data)
{"code":200,"success":true,"data":{"service":"backend","version":"38d4092","builtAt":null}}
// frontend (ตรงๆ)
{"service":"frontend","version":"f8d23a6","builtAt":null}
```

- ค่า `version` มาจาก env `APP_VERSION` ที่ deploy script `export APP_VERSION=$(git rev-parse --short HEAD)` ก่อน `compose up`
- ถ้าเห็น `"unknown"` = deploy ด้วยวิธีที่ไม่ได้ส่ง `APP_VERSION` (เก่า)
- deploy script ใช้ยิงเช็คว่า **code ใหม่ขึ้นจริงมั้ย** ผ่าน:
  ```bash
  curl -fsS --resolve dormi-api.dormi-linkandrent.com:443:127.0.0.1 \
       https://dormi-api.dormi-linkandrent.com/version
  # --resolve = บังคับวิ่ง localhost (เลี่ยง hairpin NAT) แต่ยังผ่าน TLS/edge จริง
  ```

---

## 2. สองวิธี deploy — ใช้อันไหนเมื่อไร

| | **per-service** (`dormi-backend/`, `dormi-frontend/`) | **full-update** (`dormi-full-update/`) |
|---|---|---|
| ขอบเขต | ทีละ service | ทั้ง stack (BE+FE) พร้อมกัน |
| สั่งจาก | SSH เข้า server แล้ว `bash deploy.sh` | GitHub Actions (หรือ `run-all.sh`) |
| migration | guard ในตัว (diff → backup → run) | step แยก + marker + revert DB |
| rollback | self-rollback (build commit เก่าใหม่) | image `:prev` (ไม่ build) + ประสาน FE→BE→DB |
| version log | ไม่มี | มี (`VERSION` + `RELEASES.log`) |
| เหมาะกับ | แก้ hotfix ตัวเดียวเร็วๆ | release ปกติ / มี migration / อยากเห็น step ละเอียด |

> **ปกติใช้ full-update.** per-service ไว้เป็นทางเลือกเร็วเวลาแก้ตัวเดียว

---

## 3. Full-update flow (ตัวหลัก)

### 3.1 ลำดับ + revert scope

```
prep ─► check ─► snapshot ─► migration ─► backend ─► frontend ─► version
(pull) (lock)  (tag :prev)  (diff→bkup   (build+    (build+     (บันทึก
                            →run→marker)  health)    health)     release)

พังตรงไหน → ถอยแค่ที่จำเป็น (เรียง FE→BE):
  migration พัง  → revert-db (อัตโนมัติ — ยังไม่มี traffic บน schema ใหม่)
  backend พัง    → revert-backend                    ★ DB ไม่ถอยอัตโนมัติ
  frontend พัง   → revert-frontend + revert-backend  ★ DB ไม่ถอยอัตโนมัติ

★ นโยบาย DB revert: อัตโนมัติเฉพาะ migration fail เท่านั้น
  BE/FE พัง = ผู้ใช้เขียนข้อมูลระหว่าง deploy ไปแล้ว → restore อัตโนมัติจะลบข้อมูลจริง
  → migration แบบ additive (กติกาปกติ) ไม่ต้องถอย DB เลย
  → destructive แล้วต้องถอยจริง: สั่งมือ `gh workflow run revert-db.yml`
```

### 3.2 ไฟล์ + หน้าที่ (เรียงตามที่รัน)

| ลำดับ | ไฟล์ | ทำอะไร | พังแล้ว |
|---|---|---|---|
| 0 | *(workflow prep)* | `git pull` edge clone บน server | หยุด |
| 1 | `00-check/check0-lockfile-match.sh` | `npm ci --dry-run` (node:22-alpine) เช็ค lock FE+BE ตรง package.json — บอกฝั่งที่ MISMATCH | หยุด (ยังไม่ deploy) |
| 2 | `01-prepare/snapshot.sh` | เช็ค /version 200 → **tag image รันอยู่เป็น `:prev`** → เขียน `snapshot.env` (**ไม่แตะ DB**) | หยุด |
| 3 | `02-deploy/step1-migration-run.sh` | หา migration ที่ต้องรันจริง: git diff (`--diff-filter=A` เฉพาะไฟล์เพิ่มใหม่) **+ เทียบตาราง `migrations` ใน DB** (ความจริงสุดท้าย — กัน git state หลอกหลัง revert) → มี pending → `backup.sh` → เขียน `MIGRATION_RAN` (ก่อน migrate) → build runner → `migration:run` | exit 1 → revert-db |
| 3b | `01-prepare/backup.sh` | (ถูก step1 เรียก) `pg_dump -Fc --no-owner` → `.part` → verify `pg_restore -l` → `mv` → เก็บ 20 ไฟล์ | ยกเลิก migrate |
| 4 | `02-deploy/step2-backend-deploy.sh` | `reset --hard origin/master` → `export APP_VERSION` → `compose up --build` → poll /version = commit ใหม่ | exit 1 → revert-backend+db |
| 5 | `02-deploy/step3-frontend-deploy.sh` | เหมือน step2 แต่ frontend (branch main) | exit 1 → revert ทั้งชุด |
| 6 | `02-deploy/step4-version-manager.sh` | auto `patch +1` (หรือ override) → เขียน `VERSION`+`RELEASES.log` → push `releases/` เข้า git | เตือน (ไม่ revert) |
| R2 | `03-revert/revert2-...frontend...` | `docker tag dormi-web:prev …:latest` → `compose up --no-build --force-recreate` + **reset clone → FE_COMMIT** | — |
| R1 | `03-revert/revert1-...backend...` | retag `dormi-api:prev` (+scheduler) → recreate ไม่ build + **reset clone → BE_COMMIT** (กัน detection เพี้ยนรอบถัดไป) | — |
| R0 | `03-revert/revert0-restore-db.sh` | **marker-gated**: ไม่มี marker = ข้าม; มี = rename DB เก่าเก็บไว้ (`<db>_failed_<ts>`) → create ใหม่ → `pg_restore` → **ใช้แล้วทิ้ง marker** (`.restored-<ts>` — กัน restore ซ้ำ) · ระบุไฟล์เอง = ข้าม gate | — |

### 3.3 ★ กลไกสำคัญ: ส่งค่า snapshot → revert ผ่าน "ไฟล์บน server" ไม่ใช่ GitHub

ทุก job SSH เข้า **server เดียวกัน** → ไม่ต้องส่งค่าข้าม job ผ่าน GitHub เลย ค่าอยู่บนไฟล์:

```
snapshot.sh   เขียน ─►  /root/dormi-releases/snapshots/latest/snapshot.env   (image :prev, commit เดิม)
step1         เขียน ─►  /root/dormi-releases/snapshots/latest/MIGRATION_RAN  (marker + path backup)
revert1/2     อ่าน  ◄─  snapshot.env   → รู้ว่าต้อง retag image ไหน
revert0       อ่าน  ◄─  MIGRATION_RAN  → รู้ว่าต้อง restore มั้ย + จาก backup ไฟล์ไหน
```

> เพราะแบบนี้ไม่ต้องใช้ GitHub job outputs / artifact — และ `run-all.sh` (local) กับ workflow ใช้ scripts ชุดเดียวกันเป๊ะ

### 3.4 ทำไม rollback ถึง "ไม่ build"

`snapshot.sh` tag image ที่รันอยู่ตอนนั้นเป็น `dormi-api:prev` / `dormi-web:prev` / `dormi-scheduler:prev`
→ revert แค่ `docker tag …:prev …:latest` + `compose up --no-build --force-recreate`
→ ได้ของเดิมกลับมาทันที **ไม่ต้อง build (ไม่เสี่ยง build พังซ้ำ)** และ tag กัน `docker image prune` ลบทิ้ง

### 3.5 ทำไม revert DB ถึง "ไม่ drop"

`revert0` ทำ `ALTER DATABASE dormi_v2 RENAME TO dormi_v2_failed_<ts>` แล้วสร้างใหม่ + restore
→ ของเก่าที่พัง **ยังอยู่ครบ** กู้มือได้ถ้า restore พลาด
(ไม่ rename แค่ schema `public` เพราะจะทำ extension `uuid-ossp` หลุด search_path)
marker `MIGRATION_RAN` เป็นตัวคุม: **ไม่มี migration รอบนี้ = ไม่แตะ DB เลย**

### 3.6 Version manager (step4)

- **auto** (ไม่ใส่อะไร): `0.1.3 → 0.1.4` บวก patch เรื่อยๆ ทุก deploy สำเร็จ
- **override**: ระบุ `0.2.0` / `1.0.0` เมื่ออยากกระโดด (รอบถัดไป auto ต่อจากนั้น)
- เก็บที่ `/root/dormi-releases/{VERSION,RELEASES.log}` (ตัวจริง) + push สำเนาเข้า `dormi-edge/releases/` (best-effort)
- 1 บรรทัดผูกครบ: `v0.1.4 | เวลา | be=38d4092 fe=f8d23a6 | migration=... | auto`
- รายละเอียด logic: ดู `step4-version-manager-logic.html` (โฟลเดอร์ dormi นอก repo) หรืออ่านคอมเมนต์หัวไฟล์ script

---

## 4. วิธีใช้งาน

### 4.1 เตรียมครั้งเดียว (one-time)

**GitHub Secrets** (edge repo → Settings → Secrets and variables → Actions):

| Secret | ค่า |
|---|---|
| `PROD_SERVER` | `188.166.228.210` |
| `SERVER_USER` | `root` |
| `SSH_KEY` | **private key** (ตัวที่ public อยู่ใน `authorized_keys` ของ server) |

**ให้ server push version log ได้** (ถ้าอยากให้ step4 auto-push — ต้องการแค่ scope `repo`):
```bash
# บน server
git -C /root/dormi-edge remote set-url origin \
  https://<TOKEN>@github.com/Krittater/dormi-edge.git
```
> ไม่ตั้งก็ได้ — step4 ยังบันทึกบน server ครบ แค่ข้าม push (มีคำสั่ง sync มือใน log)

**เครื่องมือ trigger** (เลือกอย่างใดอย่างหนึ่ง): `winget install GitHub.cli` แล้ว `gh auth login` — หรือใช้ web UI

### 4.2 trigger full-update

**A. GitHub CLI (local, ไม่ต้อง push):**
```bash
gh workflow run full-update.yml --repo Krittater/dormi-edge          # auto version
gh workflow run full-update.yml --repo Krittater/dormi-edge -f version=0.2.0   # override
gh run watch --repo Krittater/dormi-edge                             # ดู step สด
```

**B. Web UI:** repo → **Actions** → "Full Update (manual)" → **Run workflow** → (ใส่ version หรือเว้นว่าง) → Run

**C. รันตรงบน server (ไม่ผ่าน GitHub):**
```bash
cd /root/dormi-edge && git pull
cd deploy/dormi-full-update && bash run-all.sh          # auto
bash run-all.sh 0.2.0                                    # override
```

### 4.3 deploy ทีละ service (แบบเร็ว)

```bash
# บน server
cd /root/dormi-edge/deploy/dormi-backend  && bash deploy.sh    # backend เท่านั้น
cd /root/dormi-edge/deploy/dormi-frontend && bash deploy.sh    # frontend เท่านั้น
```

---

## 5. เมื่อพัง — เกิดอะไรขึ้น (rollback matrix)

| พังที่ | ระบบทำอัตโนมัติ | ผลลัพธ์ |
|---|---|---|
| check (lockfile) | หยุด | ยังไม่แตะอะไร — ไปแก้ lock ฝั่งที่ MISMATCH |
| snapshot | หยุด | ยังไม่ deploy |
| migration | revert-db (marker-gated) | DB คืนจาก backup, code ยังของเดิม — ปลอดภัยเพราะยังไม่มี traffic บน schema ใหม่ |
| backend | revert-backend เท่านั้น | BE กลับ `:prev` + clone reset — **DB ไม่ถอยอัตโนมัติ** (กันข้อมูลผู้ใช้หาย) |
| frontend | revert-frontend + revert-backend | FE/BE กลับ `:prev` — **DB ไม่ถอยอัตโนมัติ** |
| version (step4) | **ไม่ revert** | deploy สำเร็จแล้ว แค่บันทึก/​push พลาด — sync มือได้ |

**ถอย DB เอง (เมื่อ migration เป็น destructive และ BE/FE พัง):**
```bash
gh workflow run revert-db.yml --repo Krittater/dormi-edge          # ใช้ backup จาก marker
gh workflow run revert-db.yml -f backup_file=/root/dormi-releases/db-backups/<ไฟล์>.dump
# หรือบน server: bash 03-revert/revert0-restore-db.sh [ไฟล์]
```

---

## 6. Runbook — เจอปัญหาแล้วทำไง

**`/version` เป็น `"unknown"`**
→ ปกติหลัง deploy รอบใหม่จะเป็น SHA จริง ถ้ายัง unknown = deploy ไม่ได้ export `APP_VERSION` (ใช้ deploy.sh/step ที่อัปเดตแล้ว)

**lockfile MISMATCH**
→ ฝั่งที่แจ้ง: บนเครื่อง dev รัน `npm run lockfile` (regenerate ใน node:22-alpine) → commit `package-lock.json` → push → เริ่ม full-update ใหม่
(สาเหตุ: npm บน Windows ตัด optional deps ของ linux เช่น `@emnapi` ออกจาก lock)

**migration พัง**
→ revert-db คืน DB ให้แล้ว (rename เก่าเก็บไว้ที่ `dormi_v2_failed_<ts>`)
→ ดู error, แก้ migration บน dev, push ใหม่ · ถ้า restore ก็พลาด กู้มือ:
```bash
docker exec dormi_postgres psql -U dormi -d postgres -c \
  'DROP DATABASE "dormi_v2"; ALTER DATABASE "dormi_v2_failed_<ts>" RENAME TO "dormi_v2";
   UPDATE pg_database SET datallowconn=true WHERE datname='"'"'dormi_v2'"'"';'
```

**revert บอก "ไม่พบ image :prev (ถูก prune?)"**
→ snapshot ไม่ได้รัน/ถูกลบ → ต้อง build เอง: `bash deploy/dormi-backend/deploy.sh` (per-service) ที่ commit เดิม

**push workflow โดน reject `without workflow scope`**
→ token ที่ push ต้องมี scope `workflow` (ไฟล์ใต้ `.github/workflows/` ต้องใช้) — สร้าง PAT ที่มี `repo`+`workflow`

**restore DB จาก backup เอง (ฉุกเฉิน)**
```bash
docker exec -i dormi_postgres pg_restore -U dormi -d dormi_v2 --clean --if-exists --no-owner \
  < /root/dormi-releases/db-backups/<ไฟล์>.dump
# ⚠️ --clean = DROP ของเดิมก่อน (เขียนทับทั้งก้อน ไม่ใช่ merge)
```

**backup รายวันบน Spaces (DB + รูปสลิป) และกู้รูปสลิปคืน**

`deploy/backup/db-dump-to-spaces.sh` (cron 20:30 UTC → `/var/log/dormi-db-backup.log`) อัปขึ้น bucket `dormi-db-backups`:
- `daily/dormi-<db>-<stamp>.dump` — pg_dump ทุกฐาน
- `files/<YYYY-MM-DD UTC>.tar.gz` — tar ของ docker volume **`dormi_files_data`** (รูปสลิป/ไฟล์ที่ผู้ใช้อัป · ★ ไม่ใช่ `docker_dormi_files_data` ซึ่งว่างเปล่า) · mount แบบ `:ro` อ่านอย่างเดียว
- ทั้งสองแบบเก็บ 14 วัน (lifecycle rule ของ bucket ครอบทั้ง bucket) · สำเนาในเครื่องที่ `/var/backups/dormi` เก็บ 3 วัน
- log marker ที่ alert ใช้: `<ISO> OK <object> <bytes>` · `<ISO> FAILED: ...` · บรรทัดสุดท้าย `<ISO> DONE <unix ts>` เฉพาะเมื่อ DB + ไฟล์สำเร็จหมด (ไฟล์ล้ม = exit 5, ไม่มี DONE, แต่ DB ที่อัปแล้วยังอยู่)
- ทดสอบสคริปต์ในเครื่อง (ไม่แตะของจริง): `bash deploy/backup/test-db-dump.sh`

กู้รูปสลิปจาก Spaces (⚠️ ทับไฟล์ชื่อซ้ำใน volume — ไฟล์ที่ไม่มีใน archive ไม่ถูกลบ):
```bash
# 1) ดาวน์โหลด archive (ใช้ key จาก /root/.config/dormi-db-backup.env — อย่าพิมพ์ key ลงใน command line ของเครื่องที่คนอื่นเห็น ps)
set -a; . /root/.config/dormi-db-backup.env; set +a
D=2026-10-24   # วันที่ต้องการ (UTC)
printf 'user = "%s:%s"
' "$SPACES_KEY" "$SPACES_SECRET" | curl -fsS --config -   --aws-sigv4 "aws:amz:$SPACES_REGION:s3" -o /tmp/files-$D.tar.gz   "https://$SPACES_BUCKET.$SPACES_REGION.digitaloceanspaces.com/files/$D.tar.gz"
# (หรือใช้สำเนาในเครื่อง ถ้าไม่เกิน 3 วัน: /var/backups/dormi/dormi-files-$D.tar.gz)

# 2) ดูก่อนว่าข้างในมีอะไร แล้วค่อยกู้
tar tzf /tmp/files-$D.tar.gz | head
docker run --rm -v dormi_files_data:/d -v /tmp:/b:ro alpine:3.20 tar xzf /b/files-$D.tar.gz -C /d
```

---

## 7. กติกาที่ต้องจำ (ทำผิดแล้วเจ็บ)

- ❌ **ห้ามแก้บน server** — แก้ที่ local → push → ให้ deploy pull ลงมา (server เป็น read-only ในทางปฏิบัติ)
- ❌ ห้าม commit secret: `.env`, `*.env.production`, `*.pem`, `*.key`, `data/`, `*.dump` (มี .gitignore กันบางส่วน)
- ✅ migration = **สร้างไฟล์ใหม่เสมอ ห้ามแก้ของเก่า** (diff ใช้ `--diff-filter=A` จับเฉพาะไฟล์เพิ่มใหม่)
- ✅ cert เป็น SAN all-or-nothing **ต่อชื่อ cert** — `edge-dormi` (app. + API) กับ `edge-landing` (apex + www) แยกกัน เพื่อให้โดเมนที่ DNS ยังไม่ชี้มาไม่ทำให้ใบอื่นพัง · ออกใบ: `sh scripts/issue-cert.sh [ชื่อ cert]` (ดู `../README.md`)
- ✅ backup ก่อน migrate เสมอ (full-update ทำให้อัตโนมัติ) — ไม่ migrate โดยไม่มี backup

---

## 8. อ้างอิงไฟล์

| อยากรู้ | ดูที่ |
|---|---|
| nginx / TLS / cert / เพิ่มโดเมน | [`../README.md`](../README.md) |
| workflow (จ๊อบ + เงื่อนไข revert) | [`../.github/workflows/full-update.yml`](../.github/workflows/full-update.yml) |
| logic แต่ละ script | หัวไฟล์ `.sh` แต่ละตัว (คอมเมนต์ละเอียด) |
| version manager logic | `dormi/step4-version-manager-logic.html` |
| backend detail (compose, env, migration) | README ของ repo `dormi-backend-2` |

---

## 9. Landing (เว็บการตลาด `dormi-linkandrent.com`) — `dormi-landing/`

ย้ายจาก Vercel มาอยู่บน VPS นี้: edge รับ apex + www (cert แยก `edge-landing`) → proxy ไป container `dormi-landing:3000`

- **ไม่ build บน server** — image build ใน GitHub Actions (`release.yml` ของ repo landing, สั่งมือ) แล้วส่ง `docker save | gzip` มาที่ `/root/dormi-releases/landing-images/` → server แค่ `docker load`
- **ไฟล์:** `dormi-landing/docker-compose.yml` (project `dormi-landing`, `mem_limit 384m`) · `dormi-landing/release.sh`
- **คำสั่งบน server** (ล็อกด้วย `lib/deploy-lock.sh` เหมือน deploy อื่น):
  ```bash
  bash /root/dormi-edge/deploy/dormi-landing/release.sh inspect                    # อ่านอย่างเดียว: RAM/ดิสก์/cert/nginx -t
  bash /root/dormi-edge/deploy/dormi-landing/release.sh ensure-dummy-cert          # ทำก่อน merge edge ที่มี 40-landing.conf
  bash /root/dormi-edge/deploy/dormi-landing/release.sh deploy <tar.gz> <sha>      # โดย workflow
  ```
- **deploy flow:** ดิสก์ว่าง ≥ 3 GiB → `docker load` → tag ตัวเดิมเป็น `dormi-landing:prev` → up → healthy → ตรวจผ่าน edge (`/` = 200, `/admin` → `/admin/login`) → พังตรงไหน rollback ไป `:prev` อัตโนมัติ (ครั้งแรกที่ยังไม่มีของเดิม = `down`)
- **cert:** `edge-landing` ออกได้หลัง DNS apex + www ชี้มาที่ edge เท่านั้น: `sh scripts/issue-cert.sh edge-landing` · ก่อนนั้น nginx ใช้ dummy cert
- **runbook เต็ม** (setup ครั้งเดียว, ลำดับสลับ DNS, rollback, ปิด Vercel): `dormi/docs/pipeline/landing-to-vps/06-release.md`


---

## 10. Monitoring (Grafana Alloy → Grafana Cloud free) — `monitoring/`

container `dormi-alloy` ตัวเดียว (project `dormi-monitoring`, `mem_limit 256m`, ไม่ publish port) เก็บแล้วส่งขึ้น Grafana Cloud:

| เก็บอะไร | มาจาก | label หลัก |
|---|---|---|
| CPU / RAM / ดิสก์ / filesystem ของเครื่อง | `prometheus.exporter.unix` (mount `/proc` `/sys` `/` ของ host แบบ ro) | `job="integrations/unix"` |
| RAM / CPU / network ต่อ container + network ของเครื่อง (`id="/"`) | `prometheus.exporter.cadvisor` (`pid: host`, `cgroup: host`, containerd.sock) | `name=<container>` |
| Postgres (ขนาด DB, connection, lock, cache hit, top 20 query) | `prometheus.exporter.postgres` ผ่าน role `dormi_monitor` (`pg_monitor` อ่านอย่างเดียว) | `job="integrations/postgres"` |
| metrics แอป `dormi_*` | ทุก container ที่มี label `dormi.metrics.port` → `http://<container>:9464/metrics` ทุก 30 วิ | `job="dormi-app"`, `container`, `service` |
| log ทุก container (ทิ้งที่เก่ากว่า 48 ชม.) | docker API | `container`, `service`, `stream` (+ `feature`, `status` ของ log `[HttpRequest]`) |
| log backup DB (เวลาจากต้นบรรทัด) | `/var/log/dormi-db-backup.log` | `job="db-backup"` |

ทุก series/log ติด `env="prod"`, `host="dormi-linkandrent"`

**ตัด PII ก่อนส่งออก** (`monitoring/pii.alloy` — ใช้ร่วมกับ test): รหัสสี ANSI ของ Nest · query string ใน `uri`/`referer` · อีเมล → `[email]` · เบอร์ไทย → `[phone]` · เลข 13 หลัก → `[national-id]` · nginx error log (`request:`/`upstream:`/`referrer:` query string) · Postgres `Failing row contains (..)` → `[row]`, `Key (..)=(..)` → `=[key]`, `STATEMENT:` + บรรทัดต่อ (tab) → `[statement]`/`[continued]`, `CONTEXT:`/`QUERY:` → `[context]`/`[query]`, ค่าหลัง `: "…"` / `Token "…"` → `"[value]"` · เบอร์แบบ `66xxxxxxxxx` · IPv4 → octet สุดท้าย `.0` · IPv6 ใน `remote_addr`/`x_forwarded_for` → /48
- แก้กติกาแล้วต้องรันตรวจก่อนเสมอ: `bash deploy/monitoring/test/run-redact-check.sh` (ต้องได้ `REDACT_CHECK_PASS`)
- ตรวจ syntax: `docker run --rm -v "$PWD/deploy/monitoring:/m" grafana/alloy:v1.20.1 fmt /m/config.alloy`

**ไฟล์:** `docker-compose.yml` · `config.alloy` · `pii.alloy` · `.env.example` · `sql/create-monitor-role.sql` · `monitoring.sh` · `test/`

**ติดตั้งบน server (ครั้งแรก):**
```bash
cd /root/dormi-edge && git pull
cp deploy/monitoring/.env.example deploy/monitoring/.env && chmod 600 deploy/monitoring/.env
#   เติม GRAFANA_PROM_URL / _USER, GRAFANA_LOKI_URL / _USER, GRAFANA_CLOUD_TOKEN (จาก Grafana Cloud, H2 ในแผน)
bash deploy/monitoring/monitoring.sh setup     # สร้าง role dormi_monitor + รหัสสุ่ม → PG_MONITOR_DSN ใน .env (ไม่แสดงรหัส)
bash deploy/monitoring/monitoring.sh up        # ตรวจ .env ครบ → up → รอ healthy → แสดง RAM
bash deploy/monitoring/monitoring.sh inspect   # อ่านอย่างเดียว: สถานะ/RAM/key ที่ขาด/role/log warn ล่าสุด
```
- **ปิด/rollback:** `monitoring.sh down` (ไม่กระทบแอป — แค่หยุดส่งข้อมูล) · หมุนรหัส DB monitor: `monitoring.sh setup` ซ้ำ (recreate alloy ให้เอง)
- ทุกคำสั่งถือ `lib/deploy-lock.sh` เหมือน deploy อื่น
- edge `docker-compose.yml` เพิ่ม log rotation 10m×3 ให้ `edge`/`certbot` → มีผลเมื่อ recreate container edge ครั้งถัดไป (nginx หยุดไม่กี่วินาที)

**ข้อควรรู้:**
- `pg_stat_statements` (query ช้า top 20, ไม่ส่งข้อความ SQL) ต้องเปิดใน Postgres ก่อนถึงจะมีข้อมูล — `monitoring.sh inspect` แสดง `shared_preload_libraries` และว่ามี extension ใน DB แอปหรือยัง · ถ้า prod ยังไม่เปิด: alloy log `collector failed ... stat_statements` ทุกนาที และ Postgres เขียน ERROR + STATEMENT (~20 บรรทัด) ลง log ทุกนาที (ถูกปิดค่าแล้วแต่เพิ่มปริมาณ log) และ panel "query ช้า" = No data · การเปิดต้อง restart DB → ขออนุมัติแยก
- **ความเสี่ยงที่ยอมรับ:** alloy mount `docker.sock` + `containerd.sock` = สิทธิ์ระดับ root ของเครื่อง (`:ro` บน socket ไม่ได้จำกัด API) — จำเป็นต่อ cAdvisor/log/discovery · ลดด้วย image pin, ไม่ publish port, `no-new-privileges` (socket-proxy ยังไม่ทำ)
- อย่าให้ logrotate สร้างไฟล์ `/var/log/dormi-db-backup.log` ใหม่ (mount เป็นไฟล์เดียว) — ถ้าจะหมุนใช้ `copytruncate`
- งบ series Grafana Cloud free 10k: ทดสอบในเครื่อง (13 container) ~1.4–1.6k · ระวัง histogram `dormi_http_request_duration_seconds` บน prod (route × status × bucket × replica) · `pg_settings_*` เก็บเฉพาะ max_connections ฯลฯ
- host network: node exporter ใน container เห็นแค่ network ของตัวเอง → ใช้ `container_network_*{id="/"}` ของ cAdvisor แทน

---

*อัปเดตล่าสุด: 2026-07-12 · ครอบคลุม full-update flow + per-service deploy + edge architecture*
