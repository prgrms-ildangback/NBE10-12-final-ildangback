#!/usr/bin/env bash
# 야간 mysqldump — 7일 로컬 보관. 호스트 cron 이 04:20 KST 에 실행 (user-data.sh 등록).
# 복구 절차는 infra/docs/infra-runbook.md §4.
set -euo pipefail

# cron 은 최소 PATH 로 실행 — docker 조회 실패 대비
export PATH=/usr/local/bin:/usr/bin:/bin:$PATH

APP_DIR=/opt/team1-app
cd "$APP_DIR"

# .env 에서 DB 접속정보 로드
set -a
# shellcheck disable=SC1091
. "$APP_DIR/.env"
set +a

OUT="$APP_DIR/backups/gommit-$(date +%Y%m%d-%H%M).sql.gz"

# mysqldump 나 gzip 이 실패하면(pipefail) 잘린 .gz 가 백업처럼 남는다 → 실패 시 삭제.
trap 'rm -f "$OUT"' ERR

docker compose exec -T mysql \
  mysqldump -uroot -p"${MYSQL_ROOT_PASSWORD}" --single-transaction --routines --events "${DB_NAME}" \
  | gzip > "$OUT"

trap - ERR

echo "$(date -Is) backup ok: $OUT ($(du -h "$OUT" | cut -f1))"

# 7일 초과 삭제
find "$APP_DIR/backups" -name 'gommit-*.sql.gz' -mtime +7 -delete
