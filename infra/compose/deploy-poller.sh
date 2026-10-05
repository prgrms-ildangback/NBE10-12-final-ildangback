#!/usr/bin/env bash
# EC2 /opt/team1-app/deploy-poller.sh. team1-deploy-poller.timer 가 1분마다 실행.
# GHCR back:prod 이미지가 바뀌면 그 revision 레이블(커밋 SHA)로 deploy.sh 를 호출한다.
# 로그: journalctl -u team1-deploy-poller
set -euo pipefail

APP_DIR=/opt/team1-app
STATE_DIR="$APP_DIR/.deploy-poller"
# "<prod digest> <done|실패 횟수>"
STATE_FILE="$STATE_DIR/state"
# 있으면 배포 중단(DB 복원 등). 지우면 다음 회차부터 재개
PAUSE_FILE="$APP_DIR/.deploy-paused"
EX_TEMPFAIL=75 # deploy.sh 의 일시적 실패 코드
MAX_ATTEMPTS=2 # 같은 digest 의 일시적이지 않은 실패 허용 횟수
cd "$APP_DIR"

if [ -f "$PAUSE_FILE" ]; then
  echo "일시정지 중(${PAUSE_FILE}) — 건너뜀"
  exit 0
fi

# 스택 기동 전(최초 셋업)·기동 실패 상태에선 배포하지 않는다 — start-stack.sh 와 경합 방지
if ! systemctl is-active --quiet team1-app.service; then
  echo "team1-app.service 비활성 — 건너뜀"
  exit 0
fi

# fd 는 deploy.sh 에 상속돼 배포가 끝날 때까지 잠금 유지
exec 9>"$APP_DIR/.deploy.lock"
if ! flock -n 9; then
  echo "다른 배포 진행 중 — 건너뜀"
  exit 0
fi

# .env 는 source 하지 않는다(시크릿의 셸 메타문자)
GHCR_REPO=$(sed -n 's/^GHCR_REPO=//p' .env | tail -n 1 | sed 's/[[:space:]]*#.*$//; s/[[:space:]]*$//')
if [ -z "$GHCR_REPO" ]; then
  echo ".env 에 GHCR_REPO 없음" >&2
  exit 1
fi
IMAGE="ghcr.io/${GHCR_REPO}/back"

if ! PULL_OUT=$(docker pull "${IMAGE}:prod" 2>&1); then
  echo "${IMAGE}:prod pull 실패 — GHCR PAT 만료/권한 또는 prod 태그 없음" >&2
  echo "$PULL_OUT" >&2
  exit 1
fi

# 이미지 ID 가 아니라 prod 가 가리키는 manifest digest 로 비교한다. promote 가 승격마다
# annotation 을 달아 digest 가 바뀌므로, 같은 SHA 재승격도 새 배포로 처리된다.
DIGEST=$(sed -n 's/^Digest: //p' <<<"$PULL_OUT")
if ! [[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "docker pull 출력에서 digest 파싱 실패('${DIGEST}')" >&2
  exit 1
fi

LAST_DIGEST="" RESULT=""
if [ -f "$STATE_FILE" ]; then
  read -r LAST_DIGEST RESULT < "$STATE_FILE" || true
fi
FAILS=0
if [ "$LAST_DIGEST" = "$DIGEST" ]; then
  # 배포 끝났거나 재시도 소진 — 재승격(digest 변경) 전까지 대기
  if [ "$RESULT" = "done" ]; then
    exit 0
  fi
  if [[ "$RESULT" =~ ^[0-9]+$ ]]; then
    FAILS=$RESULT
  fi
  if [ "$FAILS" -ge "$MAX_ATTEMPTS" ]; then
    exit 0
  fi
fi

record() {
  mkdir -p "$STATE_DIR"
  echo "$DIGEST $1" > "$STATE_FILE"
}

SHA=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "${IMAGE}:prod")
if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "prod 이미지에 revision 레이블 없음('${SHA}') — 배포 안 함" >&2
  # 재시도해도 같은 결과
  record "$MAX_ATTEMPTS"
  exit 1
fi

echo "prod 변경: revision=${SHA} digest=${DIGEST} (시도 $((FAILS + 1))/${MAX_ATTEMPTS})"
rc=0
bash "$APP_DIR/deploy.sh" "${SHA:0:12}" "$SHA" || rc=$?
if [ "$rc" -eq 0 ]; then
  record "done"
elif [ "$rc" -ne "$EX_TEMPFAIL" ]; then
  # 일시적 실패(EX_TEMPFAIL)는 횟수에 넣지 않고 다음 회차에 재시도
  FAILS=$((FAILS + 1))
  record "$FAILS"
  if [ "$FAILS" -ge "$MAX_ATTEMPTS" ]; then
    echo "${MAX_ATTEMPTS}회 실패 — 재시도 중단. 고친 커밋을 배포하거나 같은 SHA 를 다시 승격(rollback_sha)" >&2
  fi
fi
exit "$rc"
