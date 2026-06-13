# Dormi Edge (global reverse proxy)

Nginx edge terminates TLS and routes traffic to **project load balancers only** (`dormi-lb`, `admin-lb`). It never talks to API or database containers directly.

## Architecture

| Hostname (prod) | Hostname (dev) | Target |
|-----------------|----------------|--------|
| `api.dormi.com` | `api.dormi.local` | `dormi-lb` → NestJS replicas |
| `dormi.com`, `www` | `dormi.local` | `frontend-dormi-landing-page:3000` |
| `admin.dormi.com` | `admin.local` | `admin-lb` → Admin NestJS replicas |

## Networks

- `edge-network` — edge + project LBs + frontend
- `dormi-network` — dormi LB, APIs, Postgres (not edge)
- `admin-network` — admin LB, APIs, Postgres (not edge)

## Hosts file (Windows, Administrator)

```
127.0.0.1 dormi.local api.dormi.local admin.local
```

## Prerequisites

1. Generate dev TLS (once):

```powershell
.\scripts\generate-dev-ssl.ps1
```

2. Copy env files:

- `projects/dormi/.env` from `projects/dormi/.env.example`
- `projects/admin/.env` from `projects/admin/.env.example`

## Start full stack (dev + HTTPS)

From repository root:

```powershell
docker compose -f docker-compose.stack.dev.yml up -d --build
```

Production edge (after real certs in `nginx/ssl/`):

```powershell
docker compose -f docker-compose.stack.yml up -d
```

## Verify

```powershell
docker exec dormi-edge nginx -t
curl -k https://api.dormi.local/health
curl -k https://api.dormi.local/api/health
curl -k https://admin.local/health
curl -k https://admin.local/api/health
curl -k http://dormi.local/
```

## Config layout

| Path | Purpose |
|------|---------|
| `nginx/nginx.conf` | Main includes |
| `nginx/conf.d/upstreams.conf` | Project LB + frontend upstreams |
| `nginx/conf.d/dormi.prod.conf` | Production dormi vhosts (mounted as `dormi.conf`) |
| `nginx/conf.d/dormi.dev.ssl.conf` | Dev HTTPS dormi vhosts |
| `nginx/conf.d/admin.prod.conf` | Production admin vhosts |
| `nginx/conf.d/admin.dev.ssl.conf` | Dev HTTPS admin vhosts |
| `nginx/conf.d/security.conf` | Security headers |
| `nginx/conf.d/rate-limit.conf` | Rate / connection limits |
| `nginx/conf.d/ssl.conf` | TLS protocols and ciphers |
| `nginx/conf.d/proxy.conf` | Shared proxy headers (included per location) |
