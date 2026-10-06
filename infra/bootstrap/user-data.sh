#!/bin/bash
# Amazon Linux 2023 (x86_64) 첫 부팅 프로비저닝.
# cloud-init 이 root 로 1회 실행. 배포물(compose/.env/nginx/certs)은 CD 가 따로 배치.
set -euxo pipefail

APP_DIR=/opt/team1-app

# ---- swap 2GiB (JVM + MySQL + ffmpeg 동시 부하 안전망) --------------------
# dd 유지: AL2023 루트 파일시스템은 XFS 라 `fallocate /swapfile` 은 unwritten 익스텐트가 되어
# `swapon` 이 "swapfile has holes" 로 거부한다 (fallocate 는 ext4 에서만 통함).
if ! swapon --show | grep -q /swapfile; then
  dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
fi

# ---- 패키지 --------------------------------------------------------------
dnf -y install docker git rsync cronie
systemctl enable --now docker
systemctl enable --now crond
usermod -aG docker ec2-user

# ---- Docker Compose 플러그인 (x86_64) --------------------------------------
COMPOSE_VERSION=v2.32.4
mkdir -p /usr/local/lib/docker/cli-plugins
curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64" \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

# ---- SSM 에이전트 (AL2023 기본 포함, 실행 보장) --------------------------
systemctl enable --now amazon-ssm-agent

# ---- 앱 디렉터리 ---------------------------------------------------------
install -d -o ec2-user -g ec2-user "${APP_DIR}"
install -d -o ec2-user -g ec2-user "${APP_DIR}/certs"       # Cloudflare Origin CA 인증서
install -d -o ec2-user -g ec2-user "${APP_DIR}/backups"     # mysqldump 출력
install -d -o ec2-user -g ec2-user "${APP_DIR}/nginx"       # deploy.sh 가 리포에서 동기화
# src/(리포 clone), .env, certs/*, 최초 docker login 은 runbook 의 "최초 1회" 절차 참고.

# ---- 야간 mysqldump cron (04:20 KST) -----------------------------------
# 04:00 배치 이후.
cat > /etc/cron.d/team1-db-backup <<'CRON'
CRON_TZ=Asia/Seoul
20 4 * * * ec2-user /bin/bash /opt/team1-app/backup.sh >> /opt/team1-app/backups/backup.log 2>&1
CRON
chmod 644 /etc/cron.d/team1-db-backup

# ---- 재부팅 시 컨테이너 자동 복귀 -----------------------------------------
cat > /etc/systemd/system/team1-app.service <<'UNIT'
[Unit]
Description=gommit docker compose stack
Requires=docker.service
After=docker.service
# 첫 배포 전(compose 파일 없음)에는 유닛을 skip — 부팅마다 failed 로 남지 않게.
ConditionPathExists=/opt/team1-app/docker-compose.yml
ConditionPathExists=/opt/team1-app/start.sh

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/team1-app
ExecStart=/usr/bin/bash /opt/team1-app/start.sh
TimeoutStartSec=600
ExecStop=/usr/bin/docker compose down
User=ec2-user

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable team1-app.service

echo "bootstrap done"
