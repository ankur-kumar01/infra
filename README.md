# host-infra

Shared **infrastructure layer** for all apps deployed on the single EC2 instance.
This repo is deployed by its own Jenkins pipeline (`host-infra` job) — the host's
nginx + certbot are **never hand-edited** on the server.

## What this owns

- Host nginx: site configs (one per app) + common settings
- Host certbot: TLS issuance (webroot) + renewal reload hook
- ufw firewall: only 22 / 80 / 443 open

## What this does NOT own

- App containers (each app repo has its own compose + Jenkins job)
- MySQL data (infra can provision DBs once via `scripts/mysql-setup.sh`)

## Port / Domain Registry — single source of truth

| App | Repo | Domain | Loopback port(s) | Route |
|---|---|---|---|---|
| finzox | `digital_viser` | finzox.example.com | 5000 | backend serves API + SPA + Socket.io + uploads |
| aviator | `Aviator` | aviator.example.com | 5011 | API + Socket.io |
| aviator | `Aviator` | aviator.example.com | 5012 | user SPA |
| aviator | `Aviator` | aviator.example.com | 5013 | admin SPA at `/admin/` |
| erp | `erp` | erp.example.com | 5021 | Next.js server |

**Adding an app:** new `nginx/<app>.conf` + entry in `scripts/domains.env` +
port registered here + `bootstrap.sh` deploy-dir loop + compose binds `127.0.0.1:<port>`.
**Never** reuse a port. **Never** bind an app to 0.0.0.0.

## Changing domains

Replace the placeholder domains in BOTH:
1. `scripts/domains.env`
2. the matching `nginx/<app>.conf` (`server_name` + snippet include name)

…in the same commit, then run the pipeline.

## Repo layout

```
Jenkinsfile            host-infra pipeline (lint → sync → bootstrap+sync+TLS → verify)
nginx/
  nginx.conf           main-context config used ONLY for CI lint (never deployed)
  common.conf          http-level settings (gzip, body size, proxy headers)
  finzox.conf          vhost → 127.0.0.1:5000
  aviator.conf         vhost → 5011 (api) / 5012 (spa) / 5013 (/admin/)
  erp.conf             vhost → 127.0.0.1:5021
scripts/
  domains.env          domains + certbot email — single source of truth
  bootstrap.sh         idempotent host provisioning (nginx, certbot, ufw, dirs)
  sync.sh              rsync confs → ssl snippets → certbot → nginx -t gate → reload → verify
  mysql-setup.sh       one-time DB + user provisioning per app
```

## TLS model

- Confs include `/etc/nginx/snippets/ssl-<domain>.conf` (managed by `sync.sh`)
- Before DNS/certbot: snippet points at a self-signed fallback (site works, browser warning)
- After issuance: snippet points at `/etc/letsencrypt/live/<domain>/`; renewals auto-reload
- `certbot certonly --webroot` — certbot never mutates our conf files

## Jenkins credentials required

| ID | Type |
|---|---|
| `infra-ec2-host` | Secret text |
| `infra-ec2-user` | Secret text |
| `infra-ec2-ssh-key` | SSH username with private key |
