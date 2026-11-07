# Terraform Backup (DigitalOcean) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the production droplet under a minimal, learnable Terraform config that turns on DO weekly backups, takes one pre-resize snapshot, and adds a daily `pg_dump` to a DO Spaces bucket that keeps 14 days.

**Architecture:** 4 small `.tf` files in `dormi-edge/terraform/`: provider pin, droplet (imported, protected from destroy), one snapshot, one private Spaces bucket with a 14-day expiry rule. One bash script in `deploy/backup/` runs on the server by cron and uploads with `curl --aws-sigv4` (already on the server, curl 8.5). Local state, gitignored. The executor writes files and runs token-free checks (`init`, `fmt`, `validate`, schema). **The user runs every command that needs the DO token** (`plan`/`apply`) in their own terminal; the executor reads the output with `mcp__terminal__read_terminal`.

**Tech Stack:** Terraform v1.16.4 (on PATH) · provider `digitalocean/digitalocean` ~> 2.0

**Spec:** `docs/superpowers/specs/2026-10-21-terraform-backup-design.md`

## Global Constraints

- Repo `C:\Users\Anuchit\Desktop\Private\dormi\dormi-edge`, branch `feature/terraform-backup` from `origin/main` (local `main` is 21 behind — do not touch it; leave the user's untracked `releases/*.html` alone).
- Never put the DO token in a file, a command line, or chat. Only `DIGITALOCEAN_TOKEN` in the user's own shell. Same for Spaces keys: Terraform reads `SPACES_ACCESS_KEY_ID` / `SPACES_SECRET_ACCESS_KEY` from the user's shell; the server reads a **bucket-limited** key from `/root/.config/dormi-db-backup.env` (chmod 600) that the user writes.
- The executor never runs `terraform plan` / `apply` / `import` / `destroy`. The user does.
- **If any `plan` shows `must be replaced` or `destroy` for the droplet → stop. Do not apply.**
- `resize_disk = false` and `lifecycle { prevent_destroy = true }` on the droplet, always.
- Keep it small: no modules, no variables files, no remote backend.
- Comments and README in Thai. Commit messages: no `Co-Authored-By` line (user memory rule).
- Do not merge or push until the user says so.

## Review Focus

1. **Import plan wants to replace the droplet** (config mismatch on image/ssh_keys/vpc) → must never be applied. → Task 2 Step 4 gate.
2. **`resize_disk` silently defaults to `true`** → a later size change would grow the disk irreversibly. → Task 2 Step 2 check.
3. **State file or token ends up in git** (state holds IPs and droplet data). → Task 1 Step 3 check.
4. **Snapshot taken while Postgres is writing** may be inconsistent. → Task 3 Step 1 takes a `pg_dump` to the user's machine first.
5. **Accidental `terraform destroy`** → `prevent_destroy` must block it. → Task 2 Step 6 check.
6. **Daily dump fails silently** (bad key, Spaces down, disk full) → script must exit non-zero, log `FAILED`, and not touch `last-success`. → Task 5 Step 1 cases.
7. **A half-written dump gets uploaded** (pg_dump dies mid-way) → upload only after `pg_dump` exits 0 and `pg_restore --list` reads the file. → Task 5 Step 1 `unreadable-dump`.

---

### Task 1: Scaffold + provider

**Files:**
- Create: `terraform/versions.tf`
- Create: `terraform/.gitignore`

**Interfaces:**
- Produces: provider `digitalocean` configured from env only; `.terraform.lock.hcl` (commit it).

- [ ] **Step 1: Write `versions.tf`** — `terraform { required_version = ">= 1.5.0"; required_providers { digitalocean = { source = "digitalocean/digitalocean", version = "~> 2.0" } } }` + empty `provider "digitalocean" {}` with a Thai comment that the token comes from `DIGITALOCEAN_TOKEN`.
- [ ] **Step 2: Write `terraform/.gitignore`**: `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfvars`, `crash.log`, `*.tfplan`.
- [ ] **Step 3: Check ignore rules.** Run in `terraform/`: `git check-ignore -v terraform.tfstate terraform.tfstate.backup .terraform/x secrets.tfvars`. Expected: all 4 listed. `git check-ignore .terraform.lock.hcl` → exit 1 (not ignored).
- [ ] **Step 4: Init + fmt + validate.** Run `terraform init`, `terraform fmt -check`, `terraform validate`. Expected: init downloads the provider, fmt prints nothing, validate `Success!`.
- [ ] **Step 5: Commit** `versions.tf`, `.gitignore`, `.terraform.lock.hcl`.

---

### Task 2: Import the droplet + weekly backups

**Files:**
- Create: `terraform/droplet.tf`

**Interfaces:**
- Consumes: Task 1 provider.
- Produces: resource address `digitalocean_droplet.dormi` (Task 3 uses `digitalocean_droplet.dormi.id`).

Values (from spec facts table): `name = "dormi-linkandrent"`, `region = "sgp1"`, `size = "s-1vcpu-2gb"`, `image = "ubuntu-24-04-x64"`, `ipv6 = false`, `monitoring = true`, `backups = true`, `resize_disk = false`. `import { to = digitalocean_droplet.dormi, id = "582380740" }`. `lifecycle { prevent_destroy = true; ignore_changes = [image, ssh_keys, user_data] }` (fields that would force a new droplet; the existing droplet was not created from this config). If the schema has a `backup_policy` block: `plan = "weekly"`, `weekday = "SUN"`, `hour = 20` (UTC window = Monday 03:00–07:00 Thai, away from the 01:00 Thai billing scheduler).

- [ ] **Step 1: Confirm `backup_policy` exists in the installed provider.** Run `terraform providers schema -json` and check `digitalocean_droplet` → `block.block_types.backup_policy`. Present → include it. Absent → `backups = true` only, note it in README.
- [ ] **Step 2: Write `droplet.tf`.** Then `grep -n "resize_disk *= *false" droplet.tf` → 1 match; `grep -n "prevent_destroy *= *true" droplet.tf` → 1 match.
- [ ] **Step 3: `terraform fmt -check` and `terraform validate`.** Expected: no output / `Success!`.
- [ ] **Step 4 (USER): `terraform plan`.** Ask the user to run, in their own terminal inside `terraform/`: set `DIGITALOCEAN_TOKEN`, then `terraform plan`. Read it with `mcp__terminal__read_terminal`. Expected: `1 to import, 0 to add, ≤1 to change, 0 to destroy`, and the only change is `backups` (and `backup_policy`). Any other diff → adjust config (or add to `ignore_changes` with a reason comment) and repeat. **`must be replaced` → stop.**
- [ ] **Step 5 (USER): `terraform apply`**, type `yes`. Expected: `Resources: 1 imported, 0 added, 1 changed, 0 destroyed` (or 0 changed if backups were already on). Then the user confirms in DO dashboard → Droplet → Backups that backups are enabled.
- [ ] **Step 6 (USER): destroy guard.** `terraform plan -destroy` must fail with `Instance cannot be destroyed`. Nothing is deleted by a plan.
- [ ] **Step 7: Commit** `droplet.tf`.

---

### Task 3: Snapshot before resize

**Files:**
- Create: `terraform/snapshot.tf`

**Interfaces:**
- Consumes: `digitalocean_droplet.dormi.id`.

`resource "digitalocean_droplet_snapshot" "before_resize" { droplet_id = digitalocean_droplet.dormi.id; name = "dormi-before-resize-2026-10" }`. Thai comment: delete this block + `apply` to remove the snapshot after the resize is verified (snapshots cost per GB-month).

- [ ] **Step 1: DB dump to the user's machine first** (executor may do this — it is read-only on prod): `pg_dump -Fc` inside `dormi_postgres` → `/root/backup-before-resize-<date>.dump` → `scp` to `C:\Users\Anuchit\Desktop\Private\dormi-backups\` (create the folder). Check: local file size > 0 and `pg_restore --list` (via the local `dormi_postgres` container) lists table data.
- [ ] **Step 2: Write `snapshot.tf`; `terraform fmt -check`; `terraform validate`.**
- [ ] **Step 3 (USER): `terraform plan`.** Expected: `1 to add` (the snapshot) and nothing else.
- [ ] **Step 4 (USER): `terraform apply`.** Expected: snapshot created (takes minutes; droplet stays on). Confirm in DO dashboard → Images → Snapshots.
- [ ] **Step 5: Commit** `snapshot.tf`.

---

### Task 4: Spaces bucket (14-day expiry)

**Files:**
- Create: `terraform/spaces.tf`

**Interfaces:**
- Produces: bucket `dormi-db-backups` (region `sgp1`, private) · endpoint `https://dormi-db-backups.sgp1.digitaloceanspaces.com` used by Task 5.

`digitalocean_spaces_bucket.db_backups`: `name = "dormi-db-backups"`, `region = "sgp1"`, `acl = "private"`, `lifecycle_rule { enabled = true; expiration { days = 14 } }`, `lifecycle { prevent_destroy = true }`. Thai comment: Spaces is a flat ~$5/month (250 GB); DigitalOcean deletes files older than 14 days itself.

- [ ] **Step 1: Write `spaces.tf`; `terraform fmt -check`; `terraform validate`.**
- [ ] **Step 2 (USER): create a full-access Spaces key** (DO → Spaces Object Storage → Access Keys → Create Access Key) for Terraform; set `SPACES_ACCESS_KEY_ID` / `SPACES_SECRET_ACCESS_KEY` in the same PowerShell with the same `Read-Host -AsSecureString` pattern as the token.
- [ ] **Step 3 (USER): `terraform plan`.** Expected: `1 to add` (the bucket) and nothing else. Name taken globally → rename to `dormi-db-backups-<4 random chars>` and record a ruling.
- [ ] **Step 4 (USER): `terraform apply`.** Then the user creates a **Limited access** key (Read/Write/Delete on this bucket only — the bucket must exist first) for the server.
- [ ] **Step 5: Commit** `spaces.tf`.

---

### Task 5: Daily dump script + cron

**Files:**
- Create: `deploy/backup/db-dump-to-spaces.sh`
- Create: `deploy/backup/dormi-db-backup.cron`
- Create: `deploy/backup/test-db-dump.sh` (local test with fake commands)

**Interfaces:**
- Consumes: bucket endpoint from Task 4.
- Produces: object key `daily/dormi-<YYYYmmdd-HHMM>.dump` · log `/var/log/dormi-db-backup.log` · `/var/backups/dormi/last-success` (UTC timestamp).

Script contract (bash, `set -euo pipefail`):
- Reads `SPACES_KEY`, `SPACES_SECRET`, `SPACES_BUCKET`, `SPACES_REGION` from `/root/.config/dormi-db-backup.env` (override path: `DORMI_BACKUP_ENV`). Missing → `FAILED: missing <NAME>`, exit 2.
- Dump: `docker exec dormi_postgres pg_dump -Fc` → `<dir>/dormi-<ts>.dump` (dir `/var/backups/dormi`, override `DORMI_BACKUP_DIR`; command override `DORMI_DUMP_CMD`). pg_dump non-zero → `FAILED: pg_dump`, exit 3, partial file removed.
- Verify: `pg_restore --list` inside the container (override `DORMI_VERIFY_CMD`). Fail → `FAILED: dump unreadable`, exit 3, no upload.
- Upload: `curl -fsS --aws-sigv4 "aws:amz:<region>:s3" --user "<key>:<secret>" -T <file> https://<bucket>.<region>.digitaloceanspaces.com/daily/<name>` (override `DORMI_UPLOAD_CMD`, called as `<cmd> <file> <name>`). Fail → `FAILED: upload`, exit 4. Secrets never written to the log.
- Success → `OK <name> <bytes>`, write `last-success`, delete local `dormi-*.dump` older than 3 days.
- Every log line starts with a UTC ISO timestamp.

Cron (installed as `/etc/cron.d/dormi-db-backup`): `30 20 * * * root /usr/local/bin/dormi-db-dump >> /var/log/dormi-db-backup.log 2>&1` (20:30 UTC = 03:30 Thai).

- [ ] **Step 1: Write `test-db-dump.sh` first** — temp env file + temp dir + fake `DORMI_DUMP_CMD` / `DORMI_VERIFY_CMD` / `DORMI_UPLOAD_CMD`. Cases:
  - `ok`: exit 0 · log has `OK dormi-` · `last-success` exists · fake uploader received the dump path.
  - `missing-secret`: env without `SPACES_SECRET` → exit 2 · `FAILED: missing SPACES_SECRET` · no upload · no `last-success`.
  - `unreadable-dump`: verify fails → exit 3 · `FAILED: dump unreadable` · no upload.
  - `upload-fails`: uploader fails → exit 4 · `FAILED: upload` · `last-success` unchanged.
  - `no-secret-in-log`: the secret value never appears in the log.
  - `cleanup`: a dump aged 4 days (`touch -d`) is deleted after an `ok` run; one aged 1 day stays.
- [ ] **Step 2: Run `bash deploy/backup/test-db-dump.sh`.** Expected: FAIL (script missing).
- [ ] **Step 3: Write `db-dump-to-spaces.sh` and the cron file.**
- [ ] **Step 4: Run the test again.** Expected: 6/6 PASS.
- [ ] **Step 5 (after the user writes `/root/.config/dormi-db-backup.env` with the limited key): install** — `scp` script → `/usr/local/bin/dormi-db-dump` (755), cron → `/etc/cron.d/dormi-db-backup` (644), `mkdir -p /var/backups/dormi`; env file must be `-rw-------` root.
- [ ] **Step 6: Run once by hand on the server.** Expected: exit 0 · log `OK dormi-…` · object listed under `daily/` in the bucket · `docker ps` still 7 up.
- [ ] **Step 7: Commit** the 3 files.

---

### Task 6: README for learning

**Files:**
- Create: `terraform/README.md` (Thai)

Contents, short: what Terraform/state/import are in 3–4 lines · what each `.tf` file does · first-time setup (token in env, `init`) · the 3 commands (`plan` = preview, `apply` = do it, never apply if `must be replaced`) · how to resize later (`size = "s-2vcpu-4gb"`, plan must say `update in-place`, `resize_disk = false` keeps it reversible, expect 2–5 min downtime, containers restart themselves) · how to delete the snapshot · where daily dumps live (bucket `daily/`, 14 days) and how to see the last run (`tail /var/log/dormi-db-backup.log`, `cat /var/backups/dormi/last-success`) · what is NOT covered (restore test, alerting when the dump fails).

- [ ] **Step 1: Write README.** Check every command in it appears in this plan and every file it names exists.
- [ ] **Step 2: Commit** README; report to the user (branch name, commits, what is now protected, what is still not).
