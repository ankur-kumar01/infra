#!/usr/bin/env bash
# One-time (idempotent) host bootstrap — safe to run on every deploy.
# Installs nginx + certbot, sets ufw, creates deploy dirs and the ACME webroot.
# Run by the host-infra Jenkins pipeline 'Bootstrap EC2' stage.
set -euo pipefail

echo "==> [bootstrap] apt update + install nginx/certbot"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx certbot python3-certbot-nginx rsync

echo "==> [bootstrap] ensure nginx running"
sudo systemctl enable --now nginx

echo "==> [bootstrap] remove Ubuntu default site (conflicts with our vhosts)"
sudo rm -f /etc/nginx/sites-enabled/default

echo "==> [bootstrap] ACME webroot"
sudo mkdir -p /var/www/certbot
sudo chown -R www-data:www-data /var/www/certbot

echo "==> [bootstrap] app deploy dirs"
for app in finzox aviator erp; do
  sudo mkdir -p "/var/www/$app"
  sudo chown -R "${DEPLOY_USER:-$USER}:${DEPLOY_USER:-$USER}" "/var/www/$app"
done

echo "==> [bootstrap] ufw firewall (idempotent)"
sudo ufw allow OpenSSH >/dev/null 2>&1 || true
sudo ufw allow 80/tcp  >/dev/null 2>&1 || true
sudo ufw allow 443/tcp >/dev/null 2>&1 || true
sudo ufw --force enable

echo "==> [bootstrap] done"
