#!/usr/bin/env bash
# Sync nginx configs from this repo to the host, issue missing certs, reload.
# Run by the host-infra Jenkins pipeline 'Deploy configs' stage.
#
# Idempotent: safe on every run.
#  1. rsync conf.d/common.conf + sites-available/<app>.conf (+ symlink)
#  2. render ssl snippet per domain:
#       - real cert exists  -> snippet -> /etc/letsencrypt/live/<domain>/
#       - no real cert yet  -> generate self-signed fallback + snippet -> it
#     (self-signed keeps nginx bootable before DNS/certbot; certbot replaces it)
#  3. certbot certonly --webroot for every domain lacking a real cert
#  4. re-render snippets (new certs flip snippets to live paths)
#  5. nginx -t (GATE — a broken conf can never be loaded) then reload
#  6. verify every domain answers (200/301/302/502 — 502 = app down, fine here)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/domains.env"

echo "==> [sync] 1/6 rsync configs"
sudo rsync -a "$SCRIPT_DIR/../nginx/common.conf" /etc/nginx/conf.d/common.conf
for app in finzox aviator erp; do
  sudo rsync -a "$SCRIPT_DIR/../nginx/$app.conf" "/etc/nginx/sites-available/$app.conf"
  sudo ln -sf "/etc/nginx/sites-available/$app.conf" "/etc/nginx/sites-enabled/$app.conf"
done

render_snippet() {
  local domain="$1"
  local live="/etc/letsencrypt/live/$domain/fullchain.pem"
  local real_cert_installed
  real_cert_installed="$(test -f /etc/letsencrypt/renewal/"$domain".conf && echo yes || echo no)"
  if [ "$real_cert_installed" = "yes" ]; then
    sudo tee "/etc/nginx/snippets/ssl-$domain.conf" >/dev/null <<EOF
ssl_certificate     $live;
ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
EOF
  else
    local ssl_dir="/etc/nginx/ssl/$domain"
    sudo mkdir -p "$ssl_dir"
    if [ ! -f "$ssl_dir/fullchain.pem" ]; then
      echo "==> [sync] self-signed fallback cert for $domain (pre-DNS bootstrap)"
      sudo openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
        -keyout "$ssl_dir/privkey.pem" -out "$ssl_dir/fullchain.pem" \
        -subj "/CN=$domain"
    fi
    sudo tee "/etc/nginx/snippets/ssl-$domain.conf" >/dev/null <<EOF
ssl_certificate     $ssl_dir/fullchain.pem;
ssl_certificate_key $ssl_dir/privkey.pem;
EOF
  fi
}

echo "==> [sync] 2/6 render ssl snippets"
sudo mkdir -p /etc/nginx/snippets
IFS=',' read -ra DOMAINS <<< "$ALL_DOMAINS"
for d in "${DOMAINS[@]}"; do render_snippet "$d"; done

echo "==> [sync] 2.5/6 nginx -t gate + reload (make ACME webroot live BEFORE certbot)"
sudo nginx -t
sudo systemctl reload nginx

echo "==> [sync] 3/6 certbot issuance (webroot, idempotent)"
for d in "${DOMAINS[@]}"; do
  if [ ! -f "/etc/letsencrypt/renewal/$d.conf" ]; then
    echo "==> [sync] requesting cert for $d"
    sudo certbot certonly --webroot -w /var/www/certbot \
      -d "$d" --email "$CERTBOT_EMAIL" --agree-tos --non-interactive \
      --keep-until-expiring || \
      echo "!! [sync] cert for $d NOT issued (DNS not pointed yet?) — self-signed fallback stays active"
  else
    echo "==> [sync] cert for $d already installed"
  fi
done

echo "==> [sync] 4/6 re-render snippets (flip to real certs where newly issued)"
for d in "${DOMAINS[@]}"; do render_snippet "$d"; done

echo "==> [sync] 5/6 nginx -t gate + reload (activate flipped snippets)"
sudo nginx -t
sudo systemctl reload nginx

echo "==> [sync] 6/6 verify every domain answers"
FAIL=0
for d in "${DOMAINS[@]}"; do
  code="$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$d:443:127.0.0.1" "https://$d/")"
  case "$code" in
    200|301|302|502) echo "    $d -> $code OK (502 just means its app container is down)" ;;
    *) echo "    $d -> $code UNEXPECTED"; FAIL=1 ;;
  esac
done
[ "$FAIL" -eq 0 ] || { echo "!! [sync] verification failed"; exit 1; }
echo "==> [sync] done"
