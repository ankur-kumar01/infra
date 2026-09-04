# Infrastructure Overview — Multi-App EC2 Hosting

> **Read this first.** This document explains the entire hosting setup: what runs where,
> why it is built this way, and how the pieces connect. Pair it with `GUIDE.md` (daily
> operations and how-to tasks).

---

## 1. The Big Picture

All company web apps run on **one AWS EC2 instance**. A **shared infrastructure layer**
(host nginx + host certbot — managed by THIS repo) routes public traffic to each app.
Every app lives in its **own GitHub repo** with its **own Jenkins pipeline** and deploys
**Docker containers bound to a private loopback port**. Nothing is reachable from the
internet except through the shared nginx.

```
                                INTERNET
                                    │  DNS: *.finzox.live → EC2 IP
                                    ▼
╔══════════════════════════════════════════════════════════════════════╗
║                        EC2  (Ubuntu, one instance)                   ║
║                                                                      ║
║  ┌─────────── INFRA LAYER — THIS REPO (host services) ────────────┐  ║
║  │  nginx  (systemd)  — THE ONLY listener on :80/:443             │  ║
║  │  certbot (systemd timer) — TLS certs, auto-renew               │  ║
║  │  ufw — only 22 / 80 / 443 open                                 │  ║
║  └───────┬──────────────────┬──────────────────┬─────────────────┘  ║
║          │ loopback         │                  │                    ║
║          ▼                  ▼                  ▼                    ║
║  ┌──────────────┐  ┌──────────────────┐  ┌──────────────┐           ║
║  │ finzox.live  │  │ aviator.finzox   │  │ erp.finzox   │           ║
║  │ :5000        │  │ .live            │  │ .live        │           ║
║  │ backend      │  │ :5011 backend    │  │ :5021 Next.js│           ║
║  │ (API+SPA+    │  │ :5012 frontend   │  │ (standalone) │           ║
║  │  socket.io)  │  │ :5013 admin      │  │              │           ║
║  │ + redis      │  │ (3 containers)   │  │              │           ║
║  └──────────────┘  └──────────────────┘  └──────────────┘           ║
║                                                                      ║
║  NATIVE MySQL — one server, separate DB + user per app               ║
╚══════════════════════════════════════════════════════════════════════╝
         ▲                    ▲                     ▲
         │ Jenkins: host-infra│ Jenkins: finzox     │ Jenkins: aviator / erp
         │ (this repo)        │ (digital_viser repo)│ (Aviator / erp repos)
```

**Why this design:**
- Only **one container can bind host ports 80/443** — so instead of each app shipping
  its own nginx (the old pattern), ONE shared nginx owns the edge and routes by domain.
- Apps stay fully independent: own repo, own CI/CD, own DB. Deploying app #2 never
  touches app #1.
- TLS is centralized — one certbot, one renewal flow, one place to reason about certs.

---

## 2. The Registry (single source of truth)

| App | Repo (GitHub) | Domain | Loopback port(s) | What runs |
|---|---|---|---|---|
| Finzox | `ankur-kumar01/digital_viser` | `finzox.live` | **5000** | Express + Socket.io + React SPA + uploads (1 backend container + redis) |
| Aviator | `ankur-kumar01/aviator` | `aviator.finzox.live` | **5011** | Express API + game engine (Socket.io) |
| | | | **5012** | User SPA (nginx:alpine serving static) |
| | | | **5013** | Admin SPA at `/admin/` |
| ERP | `ankur-kumar01/erp` | `erp.finzox.live` | **5021** | Next.js 14 standalone server |

Databases (native MySQL on the host):

| App | Database | User |
|---|---|---|
| Finzox | `finzox_db` | `finzox_user` |
| Aviator | `aviator_db` | `aviator_user` |
| ERP | `erp_db` | `erp_user` |

**Rules:**
- Never reuse a loopback port. Register new ones here AND in `GUIDE.md`.
- Apps bind `127.0.0.1:<port>` — **never** `0.0.0.0` (that would bypass nginx/TLS).
- Apps never share a MySQL database or user.

---

## 3. Repository Map

| Repo | Owns | Does NOT own |
|---|---|---|
| **infra** (this repo) | host nginx confs, certbot TLS, ufw, MySQL provisioning | app containers, app code |
| `digital_viser` | finzox backend + redis compose, Jenkins deploy job | nginx, TLS, domains |
| `aviator` | aviator backend/frontend/admin compose, Jenkins job | nginx, TLS, domains |
| `erp` | erp container compose, Jenkins job | nginx, TLS, domains |

The boundary is strict: **app pipelines cannot modify nginx; the infra pipeline cannot
touch app containers.**

---

## 4. Request Flow (example: finzox)

```
Browser ── https://finzox.live/api/wallet/deposit
   │
   ▼
HOST nginx :443            ← TLS terminated here (Let's Encrypt cert)
   │  proxy_pass http://127.0.0.1:5000        (loopback — invisible to internet)
   │  Upgrade/Connection headers forwarded    (Socket.io passthrough)
   │  X-Forwarded-Proto: https                (app's HTTPS-redirect guard needs this)
   ▼
finzox-backend container :5000
   ├── /api/*        → Express routes
   ├── /socket.io/*  → game engines / live chat
   ├── /uploads/*    → uploaded files (docker volume finzox_uploads)
   └── /*            → React SPA (static, served by Express)
```

Same pattern for the others: aviator splits `/api/`+`/socket.io/` → :5011, `/admin/` →
:5013, `/` → :5012; erp proxies everything to :5021.

---

## 5. TLS Model (how certificates work)

Certificates are issued via **`certbot certonly --webroot`** — certbot NEVER edits our
nginx configs. Instead, the site confs include a small **snippet** per domain:

```nginx
include /etc/nginx/snippets/ssl-<domain>.conf;
```

`scripts/sync.sh` renders that snippet on every run:

- **Real cert exists** (`/etc/letsencrypt/renewal/<domain>.conf` present)
  → snippet points at `/etc/letsencrypt/live/<domain>/`
- **No cert yet** (e.g. DNS not pointed) → a **self-signed fallback** is generated at
  `/etc/nginx/ssl/<domain>/` so the site still boots (browser warning only)

Renewal: certbot's systemd timer (`certbot.timer`) renews automatically; a deploy hook
reloads nginx. Nothing to do manually.

**Sequencing inside sync.sh matters** (a bug fixed the hard way):
1. rsync confs → render snippets → `nginx -t` → **reload** (ACME webroot now live)
2. certbot attempts issuance for every domain lacking a real cert
3. re-render snippets (flips to real certs where newly issued) → `nginx -t` → **reload**

---

## 6. CI/CD — 4 Jenkins Pipelines

All pipelines share **one EC2 credential set** (see `GUIDE.md` §Credentials).

| Job | Repo | Trigger | What it does |
|---|---|---|---|
| `host-infra` | infra | push / manual | rsync confs → bootstrap host → **sandboxed nginx -t lint** → deploy confs + certbot + reload + verify all domains |
| `finzox` | digital_viser | push to main | validate (node syntax check, tsc, vite build) → rsync → `compose up --build --wait` → `/api/health` verify |
| `aviator` | aviator | push to main | validate (backend tests, tsc + build ×2) → rsync → compose up → health verify |
| `erp` | erp | push to main | validate (tsc, lint, next build) → rsync → compose up → health verify |

**Deployment safety pattern (all jobs):**
1. Validation gate runs BEFORE anything touches the server.
2. `docker compose up -d --build --wait` — waits for container HEALTHCHECKs (10 min cap).
3. On failure: container state + last 50 log lines are dumped into the build log.
4. Env files come from Jenkins secret files, written server-side with `chmod 600`.

---

## 7. Security Model

| Layer | Control |
|---|---|
| Network | `ufw`: only 22/80/443 reachable; all app ports loopback-only |
| TLS | Let's Encrypt everywhere, HSTS + security headers set in nginx |
| Apps | Non-root container users; `.dockerignore` keeps `.env` out of images |
| Secrets | Jenkins credentials only — nothing sensitive in git |
| DB | MySQL bound to localhost; separate user per app, per-app grants only |
| Isolation | app pipelines ≠ infra pipeline credentials-wise (shared values, separate IDs) |

---

## 8. File-by-File Map of THIS Repo

```
Jenkinsfile            host-infra pipeline (sync → bootstrap → lint → deploy)
nginx/
  common.conf          http-level settings NOT provided by Ubuntu defaults
                       (client_max_body_size, proxy headers)
                       ⚠ do NOT add gzip/sendfile/keepalive here — Ubuntu's main
                         nginx.conf already sets them; duplicates fail nginx -t
  finzox.conf          vhost finzox.live        → 127.0.0.1:5000
  aviator.conf         vhost aviator.finzox.live → 5011 / 5012 / 5013 (/admin/)
  erp.conf             vhost erp.finzox.live     → 127.0.0.1:5021
scripts/
  domains.env          domains + certbot email — edit here AND in the .conf
  bootstrap.sh         idempotent host provisioning (nginx, certbot, ufw, dirs)
  sync.sh              confs → snippets → reload → certbot → snippets → reload → verify
  mysql-setup.sh       one-time DB + user provisioning (needs env vars, see GUIDE)
```

---

## 9. History / Context (for future readers)

- **Before this setup:** each app deployed with its own dockerized nginx + certbot
  sidecars that owned ports 80/443 — fine for ONE app, impossible for several.
- **Migration:** the old finzox stack was `compose down`-ed on the EC2 (its named
  volumes `finzox_uploads` / `finzox_redis-data` were kept and are reused by the new
  stack), host nginx+certbot installed via the `host-infra` pipeline, and the
  `finzox.live` cert from the old sidecar was found valid and reused.
- Related docs in the app repos: `MULTI_APP_ARCHITECTURE.md`,
  `MULTI_APP_IMPLEMENTATION_PLAN.md` (in `digital_viser`).
