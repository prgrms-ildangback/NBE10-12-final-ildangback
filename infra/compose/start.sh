#!/usr/bin/env bash
# EC2 /opt/team1-app/start.sh. 부팅(systemd team1-app)·수동 기동용.
# bare `docker compose up -d` 는 비활성 색까지 띄우므로 활성 색만 기동한다.
set -euo pipefail

APP_DIR=/opt/team1-app
cd "$APP_DIR"

ACTIVE_CONF="$APP_DIR/nginx/conf.d/active-backend.conf"
if grep -q 'back-blue' "$ACTIVE_CONF"; then
  ACTIVE=back-blue
elif grep -q 'back-green' "$ACTIVE_CONF"; then
  ACTIVE=back-green
else
  echo "${ACTIVE_CONF} 에서 활성 색 식별 불가" >&2
  exit 1
fi

# nginx 가 기동 시 upstream 호스트를 해석하므로 back 먼저 (mysql 은 depends_on 으로 같이 뜸)
if ! docker compose up -d --wait --wait-timeout 300 "$ACTIVE"; then
  echo "${ACTIVE} health 대기 실패 — 나머지는 계속 기동" >&2
fi

mapfile -t OTHERS < <(docker compose config --services | grep -v '^back-')
docker compose up -d "${OTHERS[@]}"
