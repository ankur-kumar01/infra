// host-infra — Jenkins CI/CD pipeline for the shared EC2 infrastructure layer.
//
// Owns: nginx site configs, certbot TLS, ufw firewall. NEVER touches app
// containers — app repos (finzox/aviator/erp) have their own pipelines.
//
// Trigger: push to main (webhook/pollSCM). Infra changes are rare — you can
// also run it manually via "Build Now".
//
// Runs entirely via SSH on the controller — needs NOTHING installed on the
// Jenkins machine (no docker, no nginx). The EC2 provides both.
//
// Credentials (Manage Jenkins → Credentials → Global) — SHARED across all
// four pipelines (host-infra, finzox, aviator, erp), same host/user/key:
//   infra-ec2-host       — Secret text, EC2 host/IP
//   infra-ec2-user       — Secret text, SSH user (e.g. `ubuntu`)
//   infra-ec2-ssh-key    — "SSH Username with private key"
//
// Safety model:
//   - configs are linted with nginx -t on the EC2 in a sandboxed /tmp dir
//     BEFORE the live sync (no docker needed, no side effects on the server)
//   - deploy re-runs nginx -t on the server; reload only happens if it passes
//   - a bad conf can therefore never take down the edge for all apps

pipeline {
    agent any

    options {
        timestamps()
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
    }

    environment {
        EC2_HOST = credentials('infra-ec2-host')
        EC2_USER = credentials('infra-ec2-user')
    }

    triggers {
        pollSCM('H/15 * * * *')
    }

    stages {
        // ---------------------------------------------------------------
        stage('Sync infra repo to EC2') {
            steps {
                sshagent(['infra-ec2-ssh-key']) {
                    sh '''
                        set -e
                        HOST="$EC2_USER@$EC2_HOST"
                        ssh -o StrictHostKeyChecking=no "$HOST" "sudo mkdir -p /var/www/infra && sudo chown -R $EC2_USER:$EC2_USER /var/www/infra"
                        rsync -avz --delete \
                          --exclude '.git' \
                          -e "ssh -o StrictHostKeyChecking=no" \
                          ./ "$HOST:/var/www/infra/"
                    '''
                }
            }
        }

        // ---------------------------------------------------------------
        stage('Bootstrap EC2 (idempotent)') {
            // Installs nginx + certbot (needed by the lint stage below),
            // ufw, deploy dirs, ACME webroot. Safe on every run.
            steps {
                sshagent(['infra-ec2-ssh-key']) {
                    sh '''
                        set -e
                        HOST="$EC2_USER@$EC2_HOST"
                        ssh -o StrictHostKeyChecking=no "$HOST" \
                          "bash /var/www/infra/scripts/bootstrap.sh"
                    '''
                }
            }
        }

        // ---------------------------------------------------------------
        stage('Lint nginx configs') {
            // Sandbox syntax check on the EC2: copies the confs into /tmp,
            // rewrites the cert-snippet includes to throwaway self-signed
            // certs, and runs nginx -t against the copy. Zero side effects
            // on the live server (no /etc/nginx changes).
            steps {
                sshagent(['infra-ec2-ssh-key']) {
                    sh '''
                        set -e
                        HOST="$EC2_USER@$EC2_HOST"
                        ssh -o StrictHostKeyChecking=no "$HOST" 'bash -s' <<'REMOTE'
set -e
LINT=/tmp/nginx-lint
rm -rf "$LINT"
mkdir -p "$LINT/nginx" "$LINT/certs"

# Source of truth for domains
. /var/www/infra/scripts/domains.env

# Copy the exact conf set that will be deployed
for f in common finzox aviator erp; do
  cp "/var/www/infra/nginx/$f.conf" "$LINT/nginx/$f.conf"
done

# Throwaway certs + rewrite snippet includes to point at them
for d in "$FINZOX_DOMAIN" "$AVIATOR_DOMAIN" "$ERP_DOMAIN"; do
  openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
    -keyout "$LINT/certs/$d.key" -out "$LINT/certs/$d.crt" \
    -subj "/CN=$d" 2>/dev/null
  sed -i "s|include /etc/nginx/snippets/ssl-$d.conf;|ssl_certificate $LINT/certs/$d.crt;\\\\n    ssl_certificate_key $LINT/certs/$d.key;|" \
    "$LINT"/nginx/*.conf
done

# Main-context test conf (mirrors what the server loads).
# Unquoted heredoc so $LINT expands to the real sandbox path.
cat > "$LINT/nginx-test.conf" <<CONF
events { worker_connections 1024; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include $LINT/nginx/common.conf;
    include $LINT/nginx/finzox.conf;
    include $LINT/nginx/aviator.conf;
    include $LINT/nginx/erp.conf;
}
CONF
nginx -t -c "$LINT/nginx-test.conf"
echo "lint OK"
REMOTE
                    '''
                }
            }
        }

        // ---------------------------------------------------------------
        stage('Deploy configs + TLS') {
            steps {
                sshagent(['infra-ec2-ssh-key']) {
                    sh '''
                        set -e
                        HOST="$EC2_USER@$EC2_HOST"
                        # bootstrap.sh is idempotent — no-op if already done
                        ssh -o StrictHostKeyChecking=no "$HOST" \
                          "bash /var/www/infra/scripts/bootstrap.sh"
                        # sync confs, manage cert snippets, certbot, nginx -t
                        # gate, reload, verify — sync.sh aborts BEFORE reload
                        # if anything is broken
                        ssh -o StrictHostKeyChecking=no "$HOST" \
                          "bash /var/www/infra/scripts/sync.sh"
                    '''
                }
            }
        }
    }

    post {
        always {
            cleanWs()
        }
    }
}
