#!/usr/bin/env bash
# EC2 /opt/team1-app/start-stack.sh. 부팅 시 team1-app.service 가 실행(수동 복구에도 사용).
# bare `docker compose up -d` 는 비활성 색까지 띄우므로 active 색만 순서대로 기동한다.
set -euo pipefail

APP_DIR=/opt/team1-app
ACTIVE_CONF="$APP_DIR/nginx/conf.d/active-backend.conf"
cd "$APP_DIR"

# 배포 중이면 기다리지 않고 종료 — 배포가 active 색을 바꾸는 중이라 지금 읽으면 어긋난다
exec 9>"$APP_DIR/.deploy.lock"
if ! flock -n 9; then
  echo "배포 진행 중(.deploy.lock) — 끝난 뒤 다시 실행" >&2
  exit 1
fi

if grep -q 'back-blue' "$ACTIVE_CONF"; then
  ACTIVE=back-blue INACTIVE=back-green
elif grep -q 'back-green' "$ACTIVE_CONF"; then
  ACTIVE=back-green INACTIVE=back-blue
else
  echo "${ACTIVE_CONF} 에서 active 색 식별 불가" >&2
  exit 1
fi

# --no-recreate: 있는 컨테이너는 그대로 시작(.env 와 어긋나도 서빙 중이던 이미지 유지)
docker compose up -d --no-recreate mysql
docker compose up -d --no-recreate --wait --wait-timeout 300 "$ACTIVE"
docker compose up -d --no-recreate nginx prometheus loki promtail grafana
# 강제 재부팅(ExecStop 미실행)이면 dockerd 가 배포 중이던 비활성 색도 되살린다
docker compose stop "$INACTIVE" >/dev/null 2>&1 || true
echo "stack up (active=${ACTIVE})"
