#!/usr/bin/env bash
# EC2 /opt/team1-app/deploy.sh. GitHub Actions 가 SSM RunCommand 로 호출:
#   bash /opt/team1-app/deploy.sh <image-tag>
# 롤백: 이미지·설정이 함께 되돌아가도록 SHA 를 두 번 넘긴다
#   (bash deploy.sh <old-12자-sha> <old-full-sha>). 인자 1개면 설정은 최신 main 이 됨.
#
# 전제 (최초 1회, infra/docs/infra-runbook.md 참고):
#   - /opt/team1-app/src        : 이 리포지토리 clone
#   - /opt/team1-app/.env       : 시크릿 (chmod 600)
#   - /opt/team1-app/certs/     : origin.pem, origin.key (Cloudflare Origin CA)
#   - /opt/team1-app/nginx/conf.d/active-backend.conf : 최초 셋업 때 blue 로 1회 생성해둠
#   - GHCR 패키지는 private → ec2-user 로 `docker login ghcr.io` 1회 (read:packages PAT)
set -euo pipefail

APP_DIR=/opt/team1-app
cd "$APP_DIR"

TAG="${1:?usage: deploy.sh <image-tag> [git-ref]}"
REF="${2:-origin/main}"

ACTIVE_CONF="$APP_DIR/nginx/conf.d/active-backend.conf"

nginx_running() {
  docker compose ps --status running --quiet nginx | grep -q .
}

# 0. 지금 active 색 판별 — repo 동기화(2번, --delete)로 conf.d 가 건드려지기 전에 먼저 읽는다.
#    이 파일을 잘못 읽은(없음/손상) 상태로 배포하면 4번이 active 컨테이너를 재기동/정지하므로 식별 불가시 배포 중단
#    (setup 단계에서 blue 로 1회 생성해두므로 정상 운영 중엔 항상 존재해야 함)
if [ ! -f "$ACTIVE_CONF" ]; then
  echo "ACTIVE_CONF(${ACTIVE_CONF}) 없음 — active 색 식별 불가, 배포 중단. infra-runbook.md 초기 셋업 확인." >&2
  exit 1
fi
if grep -q 'back-blue' "$ACTIVE_CONF"; then
  CURRENT_COLOR="blue"
elif grep -q 'back-green' "$ACTIVE_CONF"; then
  CURRENT_COLOR="green"
else
  echo "ACTIVE_CONF(${ACTIVE_CONF}) 내용에서 blue/green 식별 불가, 배포 중단:" >&2
  cat "$ACTIVE_CONF" >&2 || true
  exit 1
fi
if [ "$CURRENT_COLOR" = "blue" ]; then
  NEW_COLOR="green"
else
  NEW_COLOR="blue"
fi
echo "active=${CURRENT_COLOR} → 배포 대상(비활성)=${NEW_COLOR}"

# 1. 리포지토리를 배포 대상 커밋으로 맞춘다 (compose / nginx 설정도 여기서 옴).
#    CD 가 2번째 인자로 배포 커밋 SHA 를 넘기면 그 커밋에 고정 → 이미지와 설정이 같은 커밋.
#    인자 없으면 origin/main HEAD (수동 호출 하위호환).
git -C "$APP_DIR/src" fetch --depth 1 origin main
if [ "$REF" != "origin/main" ]; then
  git -C "$APP_DIR/src" fetch --depth 1 origin "$REF"
fi
# 직전 fetch 결과로 고정 — shallow 에서 SHA 는 로컬 ref 가 안 생김
git -C "$APP_DIR/src" reset --hard FETCH_HEAD

# 2. 배포물을 작업 디렉터리로 동기화.
#    active-backend.conf 는 repo 에 없는 런타임 생성 파일(지울 시 blue/green 색 삭제됨),
#    htpasswd 는 repo 에 없는 실물 시크릿 — 둘 다 --delete 대상에서 제외.
#    --inplace: 파일 단위로 bind mount 된 nginx.conf/prometheus.yml 등은 inplace가 없으면 inode가 바뀌어 컨테이너가 새 내용을 못 봄.
rsync -a --inplace --delete --exclude 'conf.d/active-backend.conf' --exclude '*.htpasswd' "$APP_DIR/src/infra/nginx/" "$APP_DIR/nginx/"
rsync -a --inplace --delete "$APP_DIR/src/infra/monitoring/" "$APP_DIR/monitoring/"
cp "$APP_DIR/src/infra/compose/docker-compose.yml" "$APP_DIR/docker-compose.yml"
cp "$APP_DIR/src/infra/compose/backup.sh"          "$APP_DIR/backup.sh"
# start.sh 없는 옛 커밋으로 롤백해도 죽지 않게
if [ -f "$APP_DIR/src/infra/compose/start.sh" ]; then
  install -m 755 "$APP_DIR/src/infra/compose/start.sh" "$APP_DIR/start.sh"
fi

# deploy.sh 자신도 갱신. 실행 중 파일을 in-place 로 덮으면 bash 가 깨지므로
# 임시파일 → mv(원자적 rename, inode 교체). 새 버전은 다음 배포부터 적용.
# src 에 스크립트가 없으면(옛 SHA 로 config 롤백 등) 건너뜀 — set -e 로 죽지 않게.
if [ -f "$APP_DIR/src/infra/compose/deploy.sh" ]; then
  cp -p "$APP_DIR/deploy.sh" "$APP_DIR/deploy.sh.bak" 2>/dev/null || true
  install -m 755 "$APP_DIR/src/infra/compose/deploy.sh" "$APP_DIR/deploy.sh.new"
  mv "$APP_DIR/deploy.sh.new" "$APP_DIR/deploy.sh"
fi

# 3. 이미지 태그 갱신
if grep -q '^IMAGE_TAG=' .env; then
  sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=${TAG}/" .env
else
  echo "IMAGE_TAG=${TAG}" >> .env
fi

# 3.5 새 nginx 설정(api.conf 등, active-backend.conf 제외) 사전 검증 —
#     백엔드 색 스위치 전에 실패하도록. (bind-mount 라 파일은 이미 위에서 갱신됨.)
if nginx_running; then
  docker compose exec -T nginx nginx -t
fi

# 4. 비활성 색만 새 이미지로 기동. --wait 로 컨테이너 내부 healthcheck 통과까지 블록
#    타임아웃 넉넉히 — 콜드스타트면 2분+ 걸릴 수 있음.
#    실패해도 active 색(${CURRENT_COLOR})은 그대로 running — 자동 롤백.
#    --no-deps: mysql 설정이 바뀌어도 배포 중 재생성하지 않는다 (runbook §2).
echo "pulling ghcr image (tag=${TAG})..."
docker compose pull "back-${NEW_COLOR}"
echo "starting back-${NEW_COLOR}..."
if ! docker compose up -d --no-deps --wait --wait-timeout 300 "back-${NEW_COLOR}"; then
  echo "back-${NEW_COLOR} UNHEALTHY — active(back-${CURRENT_COLOR}) 유지, 배포 중단" >&2
  docker compose ps >&2
  docker compose logs --tail=80 "back-${NEW_COLOR}" >&2
  docker compose stop "back-${NEW_COLOR}" || true
  exit 1
fi

# 5. nginx upstream 을 새 색으로 스위치. bind-mount 라 파일만 바뀌면 컨테이너 재생성 없이
#    reload 로 충분 — 끊김 없음(기존 연결은 유지, 새 연결부터 새 upstream).
#    nginx 가 떠 있으면: mv 로 상태파일을 먼저 바꾸지 않고, nginx -t 검증을 통과한 뒤에만
#    반영한다 — 먼저 바꿔버리면 검증 실패 시(set -e 로 스크립트가 죽어도) 상태파일은 이미
#    NEW_COLOR 인데 nginx 는 여전히 CURRENT_COLOR 를 서빙 중인 드리프트가 생기고, 다음 배포가
#    이 드리프트된 상태파일을 보고 실제 서빙 중인 컨테이너를 6번에서 stop 하게 된다.
cat > "$APP_DIR/nginx/conf.d/active-backend.conf.new" <<EOF
# deploy.sh 생성 파일 — git 비추적. 활성 backend 색 = 배포 상태 그 자체(0번이 이 파일을 읽음).
upstream backend {
  server back-${NEW_COLOR}:8080;
  keepalive 16;
}
EOF
if nginx_running; then
  cp "$ACTIVE_CONF" "$ACTIVE_CONF.bak"
  mv "$APP_DIR/nginx/conf.d/active-backend.conf.new" "$ACTIVE_CONF"
  if ! docker compose exec -T nginx nginx -t; then
    echo "새 nginx 설정 검증 실패 — active-backend.conf 롤백(active 는 여전히 back-${CURRENT_COLOR}), back-${NEW_COLOR} 정지, 배포 중단" >&2
    mv "$ACTIVE_CONF.bak" "$ACTIVE_CONF"
    docker compose stop "back-${NEW_COLOR}" || true
    exit 1
  fi
  if ! docker compose exec -T nginx nginx -s reload; then
    echo "nginx reload 실패 — active-backend.conf 롤백(active 는 여전히 back-${CURRENT_COLOR}), 배포 중단. back-${NEW_COLOR} 는 healthy 상태라 살려둠(nginx 만 문제)." >&2
    mv "$ACTIVE_CONF.bak" "$ACTIVE_CONF"
    exit 1
  fi
  rm -f "$ACTIVE_CONF.bak"
  echo "nginx reloaded → active=back-${NEW_COLOR}"
else
  mv "$APP_DIR/nginx/conf.d/active-backend.conf.new" "$ACTIVE_CONF"
fi

# 6. 이전 색 컨테이너 프로세스 정지 (제거 아님 — 다음 배포 때 그 색이 다시 비활성 대상으로 재사용, 이미지는 7에서 정리).
#    nginx 가 안 떠 있으면 스위치가 실제로 확인된 적이 없으므로 이전 색은 그대로 두고 경고만
#    남긴다 — 유일하게 확인된 backend 를 이유 없이 내려서 복구 여지를 줄이지 않기 위함.
if nginx_running; then
  # reload 는 기존 연결을 끊지 않지만, 그 연결이 실제로 물고 있는 back-${CURRENT_COLOR} 를
  # 곧장 stop 하면 응답 중이던 요청까지 끊긴다(앱이 graceful shutdown 을 안 씀). 옛 워커가
  # in-flight 요청을 끝낼 시간을 잠깐 준다. ffmpeg 몽타주처럼 오래 걸리는 요청 감안해 15초.
  sleep 15
  docker compose stop "back-${CURRENT_COLOR}" || true
else
  echo "nginx 미기동 — back-${CURRENT_COLOR} 유지(정지 생략). nginx 상태 확인 후 재배포 권장." >&2
fi

# 7. 안 쓰는 이미지 정리. -a = 태그만 있고 컨테이너가 안 쓰는 것도 대상(옛 back:<sha>).
#    until=24h = 최근 하루치는 남겨 빠른 롤백 시 pull 없이 되돌림. 실행 중 이미지는 항상 보호됨.
docker image prune -af --filter "until=24h" >/dev/null || true
echo "deploy ok (active=back-${NEW_COLOR})"
