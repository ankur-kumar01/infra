// host-infra — Jenkins CI/CD pipeline for the shared EC2 infrastructure layer.
//
// Owns: nginx site configs, certbot TLS, ufw firewall. NEVER touches app
// containers — app repos (finzox/aviator/erp) have their own pipelines.
//
// Trigger: push to main (webhook/pollSCM). Infra changes are rare — you can
// also run it manually via "Build Now".
//
// Credentials (Manage Jenkins → Credentials → Global):
//   infra-ec2-host       — Secret text, EC2 host/IP
//   infra-ec2-user       — Secret text, SSH user (e.g. `ubuntu`)
//   infra-ec2-ssh-key    — "SSH Username with private key"
//
// Safety model:
//   - every site conf is linted with nginx -t in a container BEFORE deploy
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
        stage('Lint nginx configs') {
            steps {
                // Syntax-check the exact conf set that will be deployed.
                // Self-signed throwaway certs satisfy the ssl directives.
                sh '''
                    set -e
                    mkdir -p lint-certs
                    for d in finzox.example.com aviator.example.com erp.example.com; do
                      openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
                        -keyout "lint-certs/$d.key" -out "lint-certs/$d.crt" \
                        -subj "/CN=$d" 2>/dev/null
                    done
                    docker run --rm -v "$PWD/nginx:/nginx:ro" -v "$PWD/lint-certs:/certs:ro" \
                      nginx:alpine sh -c '
                        mkdir -p /etc/nginx/snippets
                        for d in finzox.example.com aviator.example.com erp.example.com; do
                          printf "ssl_certificate     /certs/%s.crt;\nssl_certificate_key /certs/%s.key;\n" "$d" "$d" \
                            > "/etc/nginx/snippets/ssl-$d.conf"
                        done
                        nginx -t -c /nginx/nginx.conf
                      '
                '''
            }
        }

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
                          --exclude 'lint-certs' \
                          -e "ssh -o StrictHostKeyChecking=no" \
                          ./ "$HOST:/var/www/infra/"
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
                        # bootstrap.sh is idempotent — installs nginx/certbot/ufw,
                        # deploy dirs and ACME webroot on every run (no-ops if done)
                        ssh -o StrictHostKeyChecking=no "$HOST" \
                          "bash /var/www/infra/scripts/bootstrap.sh"
                        # sync confs, manage cert snippets, nginx -t gate, reload, verify
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
