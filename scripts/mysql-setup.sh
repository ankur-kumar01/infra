#!/usr/bin/env bash
# Create the native MySQL database + user for each app (idempotent).
# Run ONCE per server — manually or via the host-infra pipeline with
# MYSQL_ROOT_PASSWORD provided as a Jenkins secret-text credential.
#
# Apps NEVER share a DB. Each user gets privileges on its own DB only.
set -euo pipefail

: "${MYSQL_ROOT_PASSWORD:?export MYSQL_ROOT_PASSWORD=<root pw> before running}"

MYSQL="mysql -uroot -p${MYSQL_ROOT_PASSWORD} --protocol=socket"

# app_name:db_name:db_user:db_password
APPS=(
  "finzox:finzox_db:finzox_user:${FINZOX_DB_PASSWORD:?export FINZOX_DB_PASSWORD}"
  "aviator:aviator_db:aviator_user:${AVIATOR_DB_PASSWORD:?export AVIATOR_DB_PASSWORD}"
  "erp:erp_db:erp_user:${ERP_DB_PASSWORD:?export ERP_DB_PASSWORD}"
)

for entry in "${APPS[@]}"; do
  IFS=':' read -r app db user pw <<< "$entry"
  echo "==> [mysql] provisioning $app ($db / $user)"
  $MYSQL <<SQL
CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${user}'@'%' IDENTIFIED BY '${pw}';
ALTER USER '${user}'@'%' IDENTIFIED BY '${pw}';
GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'%';
FLUSH PRIVILEGES;
SQL
done

echo "==> [mysql] done — DBs created; import app data dumps into each DB as needed"
