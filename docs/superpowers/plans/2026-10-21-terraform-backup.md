# Terraform Backup (DigitalOcean) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the production droplet under a minimal, learnable Terraform config that turns on DO weekly backups and takes one pre-resize snapshot.

**Architecture:** 3 small `.tf` files in `dormi-edge/terraform/`: provider pin, droplet (imported, protected from destroy), one snapshot. Local state, gitignored. The executor writes files and runs token-free checks (`init`, `fmt`, `validate`, schema). **The user runs every command that needs the DO token** (`plan`/`apply`) in their own terminal; the executor reads the output with `mcp__terminal__read_terminal`.

**Tech Stack:** Terraform v1.16.4 (on PATH) · provider `digitalocean/digitalocean` ~> 2.0

**Spec:** `docs/superpowers/specs/2026-10-21-terraform-backup-design.md`

## Global Constraints

- Repo `C:\Users\Anuchit\Desktop\Private\dormi\dormi-edge`, branch `feature/terraform-backup` from `origin/main` (local `main` is 21 behind — do not touch it; leave the user's untracked `releases/*.html` alone).
- Never put the DO token in a file, a command line, or chat. Only `DIGITALOCEAN_TOKEN` in the user's own shell.
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

### Task 4: README for learning

**Files:**
- Create: `terraform/README.md` (Thai)

Contents, short: what Terraform/state/import are in 3–4 lines · what each `.tf` file does · first-time setup (token in env, `init`) · the 3 commands (`plan` = preview, `apply` = do it, never apply if `must be replaced`) · how to resize later (`size = "s-2vcpu-4gb"`, plan must say `update in-place`, `resize_disk = false` keeps it reversible, expect 2–5 min downtime, containers restart themselves) · how to delete the snapshot · what is NOT covered (restore test, offsite `pg_dump` to Spaces).

- [ ] **Step 1: Write README.** Check every command in it appears in this plan and every file it names exists.
- [ ] **Step 2: Commit** README; report to the user (branch name, commits, what is now protected, what is still not).
