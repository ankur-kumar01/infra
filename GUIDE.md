# Operations Guide — host-infra & Multi-App EC2

> Daily-operations manual: how to deploy, verify, change, add, and fix things.
> For architecture and background read `INFRASTRUCTURE.md` first.

---

## 0. Quick Reference

| Thing | Value |
|---|---|
| EC2 deploy dirs | `/var/www/finzox`, `/var/www/aviator`, `/var/www/erp`, `/var/www/infra` |
| Host nginx confs | `/etc/nginx/sites-available/*.conf` (+ symlinks in `sites-enabled/`) |
| Common conf | `/etc/nginx/conf.d/common.conf` |
| SSL snippets | `/etc/nginx/snippets/ssl-<domain>.conf` |
| Fallback certs | `/etc/nginx/ssl/<domain>/` (self-signed, pre-DNS) |
| Real certs | `/etc/letsencrypt/live/<domain>/` |
| App containers | see `sudo docker ps` (compose projects: finzox, aviator, erp) |
| MySQL | native on host, bound 127.0.0.1 |

**Deploy order after a fresh setup:** `host-infra` → `finzox` → `aviator` → `erp`.

---

## 1. Jenkins Credentials

Create ONCE (Manage Jenkins → Credentials → Global). All four pipelines share the
same host/user/key — the values are identical, the IDs are namespaced:

| ID | Type | Content |
|---|---|---|
| `infra-ec2-host` | Secret text | EC2 public IP / hostname |
| `infra-ec2-user` | Secret text | `ubuntu` |
| `infra-ec2-ssh-key` | SSH Username with private key | the `.pem` private key |
| `finzox-backend-env` | Secret file | full `backend/.env` for finzox |
| `aviator-backend-env` | Secret file | full `backend/.env` for aviator |

ERP needs no env file today (no DB wiring yet).

---

## 2. Everyday Deploy Flows

### An app update (e.g. finzox)
```text
push to main → finzox job runs automatically (pollSCM every 5 min)
             → or trigger manually: Jenkins → finzox → Build Now
```
Nothing else needed. App deploys NEVER touch nginx.

### An infra change (this repo)
```text
edit conf/script in this repo → commit → push
→ host-infra job: rsync → bootstrap → sandboxed lint → deploy → verify
```

### Only nginx config changed, redeploy manually
```bash
ssh ubuntu@<ec2>
bash /var/www/infra/scripts/sync.sh     # rsync already done by pipeline; this is re-apply
```

### Check what's running
```bash
sudo docker ps                                    # app containers
sudo ss -tlnp | grep -E ':80|:443|:5000|:501[123]|:5021'   # who owns which port
sudo systemctl status nginx                       # edge proxy
curl -s -o /dev/null -w '%{http_code}' https://finzox.live
```

---

## 3. Adding a New App (checklist)

1. **Pick the next free loopback port** (5022, 5023 …). Check `GUIDE.md` §Registry and
   `INFRASTRUCTURE.md` §2 — never reuse.
2. **App repo:** compose binds `127.0.0.1:<port>:<container-port>`, add a Jenkinsfile
   (copy the erp one — simplest template), add Jenkins credentials if needed.
3. **This repo:**
   - `nginx/<app>.conf` — copy `erp.conf`, change `server_name`, snippet include name,
     and `proxy_pass` port. Both HTTP→HTTPS redirect block AND 443 block.
   - `scripts/domains.env` — add `<APP>_DOMAIN` and extend `ALL_DOMAINS`.
   - `Jenkinsfile` lint stage — add the domain to the throwaway-cert loop (2 places
     in that one `sh` block: domains list appears twice).
   - `nginx/nginx-test` include list — add `include $LINT/nginx/<app>.conf;` in the
     Jenkinsfile lint heredoc.
   - `scripts/bootstrap.sh` — add the app to the deploy-dirs loop.
   - Update BOTH md files (registry tables).
4. **DNS:** A record `<subdomain>.finzox.live` → EC2 IP.
5. Run `host-infra` (self-signed fallback appears) → run the app's Jenkins job →
   on the next `host-infra` run the real cert gets issued automatically.

---

## 4. Changing a Domain

1. Edit `scripts/domains.env` (the domain + `ALL_DOMAINS`).
2. Edit the matching `nginx/<app>.conf`: `server_name` (×2) and the snippet include
   name (×1).
3. Same commit. Push → `host-infra` re-issues the cert for the new name.

---

## 5. TLS Troubleshooting

### Cert issuance failed ("unauthorized / 404")
Almost always DNS not pointing at this EC2 yet:
```bash
dig +short aviator.finzox.live        # must return the EC2 IP
```
If DNS is correct, test the webroot is served:
```bash
echo test | sudo tee /var/www/certbot/test.txt
curl http://aviator.finzox.live/.well-known/acme-challenge/test.txt   # from laptop
```
Then just re-run `host-infra` — issuance is idempotent.

### Check cert state
```bash
sudo certbot certificates
sudo ls /etc/letsencrypt/renewal/     # one .conf per real cert
```
Remember: until a real cert exists, the self-signed fallback serves the site
(browser warning is expected — that's by design).

### Force renew
```bash
sudo certbot renew --dry-run          # test the whole renewal flow safely
sudo certbot renew                    # real renewal for anything near expiry
```

---

## 6. Nginx Troubleshooting

```bash
sudo nginx -t                         # ALWAYS run this first
sudo systemctl reload nginx           # zero-downtime apply (only if -t passed)
sudo tail -50 /var/log/nginx/error.log
```

**Golden rule:** `nginx -t` must pass BEFORE any reload. A bad config that gets
loaded takes down ALL apps; one that fails the test changes nothing.

Note about `common.conf`: Ubuntu's main nginx.conf already declares
`gzip`, `sendfile`, `keepalive_timeout`, `tcp_nopush/nodelay`. Redefining those in
`common.conf` makes `nginx -t` fail with "directive is duplicate" — by design.

---

## 7. App-Level Troubleshooting

```bash
# finzox
cd /var/www/finzox && sudo docker compose -f docker-compose.prod.yml logs --tail 50 backend

# aviator (3 services)
cd /var/www/aviator && sudo docker compose -f docker-compose.prod.yml ps
sudo docker logs aviator-backend-1 --tail 50

# erp
cd /var/www/erp && sudo docker compose -f docker-compose.prod.yml logs --tail 50 erp
```

- **502 from nginx** = nginx is fine, the app container is down/unhealthy → app logs.
- **Site serves but browser shows cert warning** = self-signed fallback active, DNS
  not pointing here yet (see §5).
- **Health-check loop in a Jenkins build failed** = the compose `--wait` timed out —
  read the log dump at the end of the build (state + last 50 log lines are included).

### WebSocket disconnects in games
The site confs set `proxy_read_timeout 300s` on socket locations. If idle sockets
still drop, raise it further in the affected conf and re-run the pipeline.

---

## 8. MySQL Operations

### One-time provisioning (all three apps)
```bash
ssh ubuntu@<ec2>
export MYSQL_ROOT_PASSWORD=... FINZOX_DB_PASSWORD=... AVIATOR_DB_PASSWORD=... ERP_DB_PASSWORD=...
bash /var/www/infra/scripts/mysql-setup.sh
```
Then import any data dumps per app. Apps connect with:
- `DB_HOST=host.docker.internal` (containers reach host MySQL via the `extra_hosts`
  mapping in each compose file)

### Manual quick commands
```bash
sudo mysql
> SHOW DATABASES;
> SELECT user, host FROM mysql.user;
```
**Never** give one app's user rights on another app's DB.

---

## 9. Rollback Playbook

| Scenario | Action |
|---|---|
| Bad app deploy | re-run the previous commit's job, or `git revert` + push — pipelines are fully re-runnable |
| Bad nginx conf deployed | `nginx -t` gate should stop it pre-reload; if a bad conf is LIVE: fix forward via git (fastest), or `sudo rm /etc/nginx/sites-enabled/<app>.conf && sudo systemctl reload nginx` as emergency |
| Cert expired / broken | `sudo certbot renew --force-renewal` or fall back by deleting the renewal conf (fallback snippet re-renders next run) |
| Host nginx totally down | `sudo systemctl restart nginx`; if it won't start, read `/var/log/nginx/error.log` — usually a conf edited outside git |
| App volume missing (uploads) | volumes survive `compose down` — check `sudo docker volume ls`; NEVER `docker volume prune` on prod |

---

## 10. Housekeeping

- **Disk:** `sudo docker image prune -f` after deploys (pipelines do this for apps).
  Check `df -h` occasionally — uploads volume grows.
- **Jenkins:** builds are discarded after 10-20 runs per job (configured in each
  Jenkinsfile).
- **Server patching:** standard `sudo apt update && sudo apt upgrade` — nginx/certbot
  upgrades are safe; configs are ours, packages only change defaults in new files.
- **Cost note:** the old Aviator instance (if still running) can be stopped once
  `aviator.finzox.live` is verified on this EC2 and its DB dump is imported.

---

## 11. Known Gotchas (learned the hard way)

1. **Old stack ports:** before `host-infra` first ran, the OLD finzox compose had a
   containerized nginx owning 80/443. Any stack with its own edge container must be
   `compose down`-ed before host nginx can bind. Don't re-introduce `ports: 80:80`
   in app composes.
2. **Non-root nginx -t** needs every writable path redirected (pid, logs, temp dirs)
   AND root for the port bind — that's why lint runs `sudo` in the pipeline.
3. **Certbot before reload = 404.** The ACME webroot location must be live before
   Let's Encrypt validates — `sync.sh` therefore reloads nginx twice per run.
4. **Ubuntu nginx defaults duplicate** — see §6 note about `common.conf`.
5. **`erp` builds twice by design** (CI gate + Docker image). That's intentional;
   CI validates, Docker ships.
