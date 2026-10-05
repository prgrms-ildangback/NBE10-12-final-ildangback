# 인프라 운영 절차 (Runbook)

> 설계 배경은 `infra-design.md`. 도메인 `go-mmit.site` 는 임시 placeholder.

---

## 0. 사전 준비

| 항목 | 발급처 | 쓰이는 곳 |
|---|---|---|
| `aws login` profile (인프라 담당자) | 프로젝트 계정 `AccountFullAccessRole` 세션 | `terraform apply`, 수동 조작 |
| Cloudflare 존 + API 토큰 (Zone.DNS 편집) | CF 대시보드 → My Profile → API Tokens | `terraform.tfvars` |
| 도메인 | Cloudflare Registrar | — |
| GitHub 리포 관리자 권한 | — | Secrets, Environments |

---

## 1. 최초 배포

### 1-1. Cloudflare

1. 도메인 구매 (Cloudflare Registrar 면 네임서버 자동). 존 ID 확인 (Overview 우측 하단)
2. SSL/TLS → **Full (strict)**
3. SSL/TLS → Origin Server → Create Certificate → `*.go-mmit.site`, `go-mmit.site` → PEM 저장

### 1-2. Terraform

```bash
aws login --profile <profile>
# provider 5.x 가 login_session 을 못 읽어 임시 키를 env 로 넘김. 만료 시 재실행
eval "$(aws configure export-credentials --profile <profile> --format env)"
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # 계정 ID, cloudflare_*, alert_emails, budget_*
terraform init
terraform apply
```

- 다른 계정 profile 이면 `allowed_account_ids` 로 실패한다
- SNS 구독 확인 메일을 수신자 전원이 클릭해야 알림이 간다
- apply 할 때마다 `terraform.tfstate` 를 팀 드라이브에 업로드 (시크릿 취급). **apply 는 담당자 1인만**

### 1-3. GitHub

Settings → Secrets and variables → Actions:

| Secret | 값 |
|---|---|
| `EC2_INSTANCE_ID` | output `instance_id` |
| `AWS_DEPLOY_ROLE_ARN` | output `deploy_role_arn` |

Settings → Environments → **`production`** 생성 (Terraform `deploy_environment` 와 같은 이름):
- **Required reviewers 1명 이상.** dispatch 로 다른 브랜치가 배포되는 것(`:latest` 이동 포함)을 막는 유일한 장치

GHCR PAT: Developer settings → Personal access tokens (classic) → `read:packages` 만. 1-4 에서 사용.

### 1-4. EC2 최초 셋업

```bash
aws ssm start-session --target <instance-id> --region ap-northeast-2
sudo su - ec2-user
cd /opt/team1-app

git clone --depth 1 https://github.com/prgrms-ildangback/NBE10-12-final-ildangback.git src

vi certs/origin.pem && vi certs/origin.key && chmod 600 certs/origin.key   # 1-1 인증서

cp src/infra/compose/.env.example .env && vi .env && chmod 600 .env

echo <GHCR_PAT> | docker login ghcr.io -u <github-user> --password-stdin   # ec2-user 로

cp src/infra/compose/{docker-compose.yml,backup.sh,deploy.sh,start.sh} .
chmod +x deploy.sh start.sh
rsync -a src/infra/nginx/ nginx/
rsync -a src/infra/monitoring/ monitoring/
# grafana.htpasswd 생성: nginx/conf.d/grafana.htpasswd.example 참고

# 활성 색 최초 지정 (없으면 nginx 기동 실패). 이후 deploy.sh 가 관리
cat > nginx/conf.d/active-backend.conf <<'EOF'
upstream backend {
  server back-blue:8080;
  keepalive 16;
}
EOF

# 활성 색만 기동. bare `docker compose up -d` 금지 (두 색이 다 뜸)
./start.sh
docker compose ps
```

### 1-5. 프론트 (Cloudflare Workers)

- `.github/workflows/deploy-front.yml`(`wrangler deploy`)로 배포. repo variable `VITE_API_BASE_URL=https://api.go-mmit.site`
- Workers → Custom domains → `go-mmit.site` (apex 레코드 자동 생성)

### 1-6. 확인

```bash
curl -I https://api.go-mmit.site/actuator/health   # 200
```

---

## 2. 일상 배포

`main` 에 백엔드/인프라 변경 머지 → `deploy.yml` → 리뷰어 승인 → `deploy.sh <sha12> <full-sha>` (blue/green 전환).

- 수동: Actions → Deploy Backend → Run workflow
- 인스턴스가 꺼져 있으면 실패한다 (Budget 정지 가능성, §5). 재개 결정 후에만 `start_if_stopped` 체크
- 04:00~04:30 (배치) 배포는 피한다
- 배포는 back 만 재생성한다. mysql·nginx·모니터링 compose 설정 변경은 한산한 시간에 `docker compose up -d <서비스>` 로 직접 적용 (mysql 은 수십 초 중단)
- GHCR PAT 만료 시 `docker compose pull` 이 `denied` 로 실패 → 재발급 후 1-4 `docker login` 다시

---

## 3. 롤백

```bash
aws ssm start-session --target <instance-id> --region ap-northeast-2
sudo -u ec2-user bash /opt/team1-app/deploy.sh <이전-sha12> <이전-full-sha>
```

- 이미지와 `src`(compose/nginx 설정)가 같은 커밋으로 돌아간다. 태그 목록은 GHCR Packages 에서 확인
- `:latest` 는 그대로다. dispatch 는 브랜치·태그만 받아 임의 SHA 롤백에는 못 쓴다

---

## 4. DB 백업 / 복구

- **자동**: cron 04:20 `backup.sh` → `/opt/team1-app/backups/gommit-YYYYMMDD-HHMM.sql.gz`, 7일 보관
- EBS 스냅샷은 수동만 (EC2 콘솔)

```bash
cd /opt/team1-app
gunzip -c backups/gommit-YYYYMMDD-HHMM.sql.gz | \
  docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" gommit
docker compose restart "$(grep -om1 'back-[a-z]*' nginx/conf.d/active-backend.conf)"
```

인스턴스를 새로 만들어야 하면: 스냅샷이 있으면 볼륨 복원, 없으면 `terraform taint aws_instance.app && terraform apply` 후 1-4 → 덤프 복구.

> **규칙**: DB 를 초기화하면 Cloudinary 미디어도 함께 정리한다 (고아 파일 방지).
> 옛 서버와 Cloudinary 를 공유하는 동안 운영 데이터 DB 로 새 서버 앱을 띄우지 않는다.

---

## 5. 인스턴스 정지 / 기동

- **24시간 가동.** OS 무응답 5분 → 자동 reboot + 메일
- **Budget**: 실제 누적이 `budget_alert_usd` 를 넘거나 예측이 `budget_limit_usd` 를 넘으면 메일. **`budget_stop_usd` 에서 EC2 자동 stop**
- **재개**: 팀 결정 → `terraform.tfvars` 의 `budget_limit_usd`·`budget_stop_usd` 상향 → `apply` → 콘솔 Budgets → Actions 상태 확인 → Deploy Backend 를 `start_if_stopped` 체크로 실행 (또는 output `ec2_start_command`)
- 부팅 시 `team1-app.service` 가 `start.sh` 로 활성 색만 기동. 안 뜨면 `sudo systemctl restart team1-app` 또는 `/opt/team1-app/start.sh`
- EIP 라 IP 그대로

---

## 6. 셸 접속 / 로그

```bash
aws ssm start-session --target <instance-id> --region ap-northeast-2
cd /opt/team1-app
docker compose ps
grep back nginx/conf.d/active-backend.conf       # 활성 색
docker compose logs -f --tail=100 back-blue      # 또는 back-green
docker stats --no-stream; free -h
```

로그·메트릭은 `https://grafana.go-mmit.site` (Basic Auth + Grafana 로그인).

### 6-1. SSH 예외 접속 (Q14 추가결정)

SSM 을 못 쓰는 운영자만.

1. 그 사람이 `ssh-keygen -t ed25519 -C team1-ops -f ~/.ssh/team1` → 공개키만 전달
2. `terraform.tfvars` 에 `ssh_allowed_cidrs = ["<그사람-IP>/32"]` → `apply` (SG 만 변경)
3. SSM 으로 등록:
   ```bash
   sudo -u ec2-user tee -a /home/ec2-user/.ssh/authorized_keys <<'KEY'
   ssh-ed25519 AAAA... team1-ops
   KEY
   ```
4. 접속: `ssh -i ~/.ssh/team1 ec2-user@<EIP>`

IP 가 바뀌면 2번만, 인스턴스를 새로 만들면 3번을 다시.

---

## 7. 트러블슈팅

| 증상 | 확인 |
|---|---|
| 배포 health check 실패 | 배포 대상 색 로그 — Flyway/DB 연결/OOM. 활성 색은 유지되어 서비스는 안 끊김 |
| back OOM-kill 반복 (인코딩 중) | `docker stats`. 2회 이상이면 design Q24 ffmpeg 확장 순서 |
| Cloudflare 502 | nginx up? `certs/origin.*`? `docker compose logs nginx` |
| Cloudflare 526 | Origin CA 인증서 불일치, SSL 모드 Full(strict) |
| 배포 `instance is stopped` | Budget 정지 메일 확인 → §5 |
| SSM 명령 안 감 | 인스턴스 running? IAM 역할 `team1-app-role` 붙었나? |

---

## 8. 정리 (프로젝트 종료 시)

```bash
cd infra/terraform && terraform destroy
```

Cloudflare Workers 프로젝트 삭제, 도메인 자동갱신 off, GHCR 패키지 삭제.
