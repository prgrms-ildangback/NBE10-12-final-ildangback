# 인프라 운영 절차 (Runbook)

> 설계 배경은 `infra/docs/infra-design.md`. 이 문서는 "무엇을 어떻게 실행하나".
> 도메인은 `go-mmit.site` 로 표기 — 임시 placeholder, 구매 시 실제 값으로 치환.

---

## 0. 사전 준비 (계정·크레덴셜)

| 항목 | 발급처 | 쓰이는 곳 |
|---|---|---|
| AWS IAM 사용자 (인프라 담당자) | 팀 AWS 계정 | `terraform apply`, 수동 조작 |
| Cloudflare 계정 + 존 | cloudflare.com | DNS, Workers, Origin CA |
| Cloudflare API 토큰 (Zone.DNS 편집) | CF 대시보드 → My Profile → API Tokens | `terraform.tfvars` |
| 도메인 | Cloudflare Registrar (권장) | — |
| GitHub 리포 관리자 권한 | — | Environment·Variables 등록 |
| GitHub PAT (classic, `read:packages`) | 패키지를 읽을 수 있는 계정 | EC2 `docker login` (1-3) |

> GitHub 에는 AWS 자격증명을 두지 않는다. 배포는 EC2 폴러가 GHCR 을 감시하는 Pull 방식 (design Q30).

---

## 1. 최초 배포 (한 번만)

### 1-1. 도메인 + Cloudflare

1. Cloudflare Registrar 에서 `go-mmit.*` 구매 (첫해 가격 확인 — `infra/docs/infra-design.md` Q23).
   Cloudflare 에서 사면 네임서버는 자동.
2. 대시보드에서 **존 ID** 확인 (Overview 우측 하단).
3. SSL/TLS → **Full (strict)**.
4. SSL/TLS → Origin Server → **Create Certificate** →
   `*.go-mmit.site`, `go-mmit.site` → PEM 저장 → 나중에 EC2 `certs/` 에 배치.

### 1-2. Terraform

```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars   # cloudflare_zone_id, cloudflare_api_token 채움
terraform init
terraform apply
```

출력값 `instance_id` 는 SSM 세션 접속(1-4, 6장)에 쓴다. GitHub 에 등록할 AWS 값은 없다.

DNS 레코드 이름은 변수다 (`api_subdomain`, `grafana_subdomain`).
옛 서버가 `api` 를 쓰는 동안(계정 이전 테스트) 새 서버는 `api-next` 로만 띄운다:
```hcl
api_subdomain     = "api-next"
grafana_subdomain = ""          # 빈 문자열 = 레코드 안 만듦
```
컷오버 때 `"api"` / `"grafana"` 로 바꿔 apply. nginx `server_name` 은 `api`·`api-next` 둘 다 받으므로
수정 불필요, Origin CA 도 `*.go-mmit.site` 라 재발급 불필요.

> ⚠️ `apply` 직후 `terraform.tfstate` 를 팀 드라이브에 업로드 (시크릿 파일 취급, git 아님).
> 이후에도 `apply` 할 때마다 갱신본 업로드. **인프라 담당자 1인만 apply.**

### 1-3. GitHub Environment + Variables

> fork/새 리포는 environments·secrets·variables 를 복사하지 않는다 — 새 리포에서 다시 만든다.

리포 Settings → Environments → **`production` 생성**:
- `deploy.yml` 의 `promote` job(`back:<sha>` → `back:prod` 재태깅)이 이 환경에서 돈다.
  EC2 폴러는 `prod` 만 보므로 **이 승인이 운영 반영의 유일한 게이트**다.
- **Deployment protection rules → Required reviewers 를 1명 이상.** 혼자 테스트할 땐
  "Prevent self-review" 를 끈다.
- **Deployment branches**: 운영은 `main` 만. 머지 전 브랜치 검증 기간에만 작업 브랜치를 추가하고, 끝나면 뺀다.

리포 Settings → Secrets and variables → Actions → **Variables**:

| Variable | 값 |
|---|---|
| `DEPLOY_VERIFY_URL` | `deploy.yml` verify job 이 `/actuator/info`·`/actuator/health` 를 폴링할 주소. 테스트 중 `https://api-next.go-mmit.site`, 컷오버 후 `https://api.go-mmit.site` |

Secrets 는 배포용으로 필요 없다 (`GITHUB_TOKEN` 이 GHCR push·재태깅에 자동 제공).
옛 `AWS_DEPLOY_ROLE_ARN`, `EC2_INSTANCE_ID` 는 등록하지 않는다.

GHCR 패키지는 **private 로 둔다.** 리포는 public 이지만 이미지에는 빌드 산출물·의존성이 들어가므로
익명 pull 을 열지 않는다. EC2 에서 pull 하려면 자격증명이 필요하다:

1. GitHub → Settings → Developer settings → Personal access tokens **(classic)** →
   Generate → `read:packages` **스코프만** 체크.
2. 만료일: 설정하면 만료 전 재발급 + EC2 재로그인 필요 (아래 §2 에 갱신 메모). 무기한 토큰은 지양.
   PAT 주인 계정이 org 패키지(`ghcr.io/prgrms-ildangback/...`)를 읽을 수 있는지 확인.
3. 토큰 문자열을 1-4 의 `docker login` 단계에서 쓴다. `~ec2-user/.docker/config.json` 에 저장돼
   재부팅·재배포 후에도 유지된다.

### 1-4. EC2 최초 셋업 (SSM 세션으로)

```bash
aws ssm start-session --target <instance-id> --region ap-northeast-2
sudo su - ec2-user
cd /opt/team1-app

# 리포 clone (private 이면 read-only deploy key 등록 후)
git clone --depth 1 https://github.com/prgrms-ildangback/NBE10-12-final-ildangback.git src

# Origin CA 인증서 배치
vi certs/origin.pem      # 1-1 에서 만든 인증서 본문
vi certs/origin.key      # 개인 키
chmod 600 certs/origin.key

# .env 작성 (템플릿: src/infra/compose/.env.example)
cp src/infra/compose/.env.example .env
vi .env                  # DB 비번, JWT_SECRET_KEY, Cloudinary, CORS 등. IMAGE_TAG=prod 그대로(최초 기동용)
chmod 600 .env

# GHCR 로그인 (패키지 private) — ec2-user 로 실행할 것. 폴러·deploy.sh 도 ec2-user 로 돌기 때문.
# config.json 에 저장돼 재부팅·재배포 후에도 유지됨. 토큰은 1-3 의 read:packages PAT.
echo <GHCR_PAT> | docker login ghcr.io -u <github-user> --password-stdin

# 최초 기동
cp src/infra/compose/docker-compose.yml .
cp src/infra/compose/backup.sh .
# 스크립트들은 이후 deploy.sh 가 매 배포마다 갱신.
install -m 755 src/infra/compose/{deploy,deploy-poller,start-stack}.sh .
rsync -a src/infra/nginx/ nginx/
rsync -a src/infra/monitoring/ monitoring/

# blue-green active 색 최초 지정(1회) — nginx 가 include 하는 upstream 정의라 이거 없으면
# nginx 기동 자체가 실패함. 이후로는 deploy.sh 가 이 파일을 읽고/새로 씀(git 비추적).
cat > nginx/conf.d/active-backend.conf <<'EOF'
# deploy.sh 생성 파일 — git 비추적. 활성 backend 색 = 배포 상태 그 자체.
upstream backend {
  server back-blue:8080;
  keepalive 16;
}
EOF

# 최초 기동 — systemd 유닛으로. start-stack.sh 가 mysql → active 색 → nginx → 모니터링 순으로 띄운다.
# 유닛을 active 로 만들어 둬야 다음 재부팅 때 ExecStop(compose stop)이 돈다.
exit                                   # ec2-user → 원래 사용자
sudo systemctl start team1-app
sudo -u ec2-user docker compose -f /opt/team1-app/docker-compose.yml ps
```

> bare `docker compose up -d` 는 쓰지 않는다 — back-blue/back-green 이 둘 다 뜬다.

**폴러 확인** — user-data 가 timer 를 enable 해두었고, `deploy-poller.sh`·`.env` 가 생긴 순간부터 1분마다 돈다.
첫 회차는 상태 파일이 없어 지금 `prod` 이미지로 blue/green 한 번 더 배포한다(같은 이미지, 무해).

```bash
systemctl list-timers team1-deploy-poller.timer
journalctl -u team1-deploy-poller -n 50 --no-pager
```

### 1-5. Cloudflare Workers (프론트) — Pages 아님, 대시보드가 통합돼 신규 프로젝트는 기본 Workers

> Git 연동(Workers Builds)이 끊긴 상태라 지금은 `.github/workflows/deploy-front.yml`
> (GitHub Actions, `wrangler deploy`)로 배포함 — `infra-design.md` Q8 참고. 아래는 연동
> 복구 시 참고용 원래 절차.

1. Workers & Pages → Create → Connect to Git → 리포 선택.
2. Build: root `front`, command `pnpm build`, output `dist`, Node 20+.
3. 환경변수: `VITE_API_BASE_URL=https://api.go-mmit.site` — `front/.env.production` 은
   커밋하지 않음(관례상 `.env.example` 외 `.env*` 파일은 git에 안 넣음). Cloudflare 대시보드의
   프로젝트 환경변수로 직접 등록해야 함. 지금 쓰는 GitHub Actions 경로(`deploy-front.yml`)는
   같은 값을 repo variable `vars.VITE_API_BASE_URL` 로 등록해 빌드 직전에 주입한다.
4. Custom domains → `go-mmit.site` 추가 → Cloudflare 가 apex 레코드 자동 생성.

### 1-6. 확인

```
curl -I https://api.go-mmit.site/actuator/health   # 200 (테스트 중엔 api-next)
curl https://api.go-mmit.site/actuator/info        # {"app":{"revision":"<커밋 SHA>"}}
open https://go-mmit.site                          # 프론트
```

---

## 2. 일상 배포

`main` 에 백엔드/인프라 변경 머지 → `deploy.yml`:

1. **build** — 이미지 빌드 → GHCR `back:<12자-sha>` push. 커밋 SHA 가 이미지 레이블
   (`org.opencontainers.image.revision`)과 앱 `/actuator/info` 의 `app.revision` 에 들어간다.
2. **promote** — `production` 승인 대기 → 승인되면 `back:<sha>` 를 `back:prod` 로 재태깅.
3. **EC2 폴러** (`team1-deploy-poller.timer`, 1분) — `prod` 이미지가 바뀐 걸 보고 레이블의 SHA 로
   `deploy.sh <12자-sha> <풀-sha>` 실행 (blue/green, `src` 를 그 커밋에 고정 → 이미지와 compose/nginx 설정이 같은 커밋).
4. **verify** — `DEPLOY_VERIFY_URL` 의 `/actuator/info` revision 이 커밋 SHA 이고 health 가 UP 이 될 때까지 최대 10분 폴링.

수동 실행: Actions → Deploy Backend → Run workflow (브랜치 선택, `rollback_sha` 비움).

**배포 금지 시간대**: 04:00~04:30 (정산 배치 + 04:20 mysqldump).

**verify 가 타임아웃되면** — EC2 에서 `journalctl -u team1-deploy-poller -n 100`:
- `pull 실패` → GHCR PAT 만료/권한. 아래 PAT 갱신 후엔 다음 회차에 저절로 진행된다.
- `git fetch 실패` / `이미지 pull 실패`(deploy.sh) → 일시적 실패. 폴러가 다음 회차에 자동 재시도.
- `UNHEALTHY` / nginx 검증 실패 → 새 색이 안 떴고 active 색은 그대로 서빙 중. back 로그 확인(7장).
  폴러는 같은 `prod` digest 를 2회까지만 시도한다 — 고쳐서 새 커밋을 배포하거나, 같은 SHA 를 `rollback_sha` 로 다시 승격.
- `revision 레이블 없음` → 전환 전에 빌드된 옛 이미지를 승격함. 레이블 있는 SHA 로 다시.

**GHCR PAT 갱신**: 만료일 있는 PAT 를 썼다면 만료 전에 새 토큰 발급 → EC2 에서 ec2-user 로
`docker login` 다시 (1-4 명령 동일). 만료되면 폴러의 `docker pull` 이 `denied` / `unauthorized` 로 실패하고,
CI 에는 verify 타임아웃으로만 드러난다.

---

## 3. 롤백

Actions → Deploy Backend → Run workflow → `rollback_sha` 에 **되돌아갈 커밋의 풀 SHA(40자)**.
빌드 없이 그 이미지를 승인 후 `prod` 로 승격 → 폴러가 이미지와 설정(`src`)을 그 커밋으로 되돌린다.
EC2 접속 불필요.

- 이전 이미지는 GHCR 에 `back:<12자-sha>` 로 남아 있다 (GHCR Packages 에서 태그 확인).
- 대상은 이 Deploy Backend 워크플로가 빌드한 커밋이어야 한다(revision 레이블·`/actuator/info` 필요).
  GHCR 에 태그가 없는 SHA 면 `Retag to prod` 가 not found 로 실패하고 `prod` 는 그대로다.
- EC2 의 `docker image prune` 은 24시간 지난 미사용 이미지를 지운다 — 더 오래된 버전이면 자동으로 다시 pull.

비상시(GitHub 장애 등) 수동: SSM 세션에서 `sudo -u ec2-user bash /opt/team1-app/deploy.sh <12자-SHA> <풀-SHA>`.
단 `prod` 태그는 그대로라 폴러와 어긋나지 않도록, GitHub 복구 후 같은 SHA 로 롤백 dispatch 를 한 번 해 둔다.

---

## 4. DB 백업 / 복구

- **자동**: 호스트 cron 이 매일 04:20 `backup.sh` → `/opt/team1-app/backups/gommit-YYYYMMDD-HHMM.sql.gz`, 7일 보관.
- 볼륨 단위 자동 스냅샷(DLM)은 계정 규칙상 부수 서비스 결재 회피를 위해 제외했다.
  필요 시 EC2 콘솔에서 루트 볼륨 스냅샷을 수동으로 찍을 수 있다.

### 논리 복구 (mysqldump 에서)

복원 중엔 배포를 멈춘다: `touch /opt/team1-app/.deploy-paused` (끝나면 `rm`).

```bash
cd /opt/team1-app
gunzip -c backups/gommit-YYYYMMDD-HHMM.sql.gz | \
  docker compose exec -T mysql mysql -uroot -p"$MYSQL_ROOT_PASSWORD" gommit
# back 은 blue-green 이라 서비스명이 back-blue/back-green 로 나뉜다 — 지금 active 인
# 쪽만 재시작(비활성 쪽까지 건드리면 안 쓰는 컨테이너가 괜히 뜬다).
ACTIVE=$(grep -om1 'back-[a-z]*' nginx/conf.d/active-backend.conf)
docker compose restart "$ACTIVE"
```

### 볼륨 복구 (수동 스냅샷에서)

인스턴스 교체가 필요한 수준의 사고일 때. 수동으로 찍어둔 스냅샷이 있으면 EC2 콘솔에서
스냅샷 → 볼륨 생성 → 루트 교체. 없으면 `terraform taint aws_instance.app && terraform apply`
로 인스턴스를 새로 만든 뒤 mysqldump 백업에서 논리 복구.

> **규칙**: DB 를 초기화(wipe)하면 미디어 스토리지도 함께 정리한다 (Cloudinary 폴더 / 로컬 dir).
> 안 그러면 고아 파일이 쌓인다. — `infra/docs/infra-design.md`, 미디어 설계 메모.

---

## 5. 가동 / 재부팅

- **24시간 가동.** 정지 스케줄 없음(옛 계정의 03:30 자동 기동 Scheduler 는 삭제).
- **자동 재부팅**: CloudWatch 알람 `team1-app-instance-check-reboot` — 인스턴스 상태 검사
  (`StatusCheckFailed_Instance`) 3분 연속 실패(메모리 고갈 등 OS 무응답) 시 EC2 reboot.
- **수동 기동**(누가 stop 했을 때): `aws ec2 start-instances --instance-ids <id> --region ap-northeast-2`
- 재부팅/기동 후 `team1-app.service`(`start-stack.sh`)가 active 색만 띄우고, 폴러는
  `team1-deploy-poller.timer` 로 자동 복귀. 종료 시에는 `docker compose stop`(컨테이너 유지).
  안 뜨면: `journalctl -u team1-app` 확인 후 `sudo systemctl restart team1-app`.
  **bare `docker compose up -d` 금지** — 비활성 색까지 같이 뜬다.
- EIP 덕분에 정지/기동 후에도 공인 IP 는 그대로 → DNS 수정 불필요.

---

## 6. 셸 접속 / 로그

**기본 경로 (SSM) — IAM 자격증명이 있는 사람 (인프라 담당자):**

```bash
aws ssm start-session --target <instance-id> --region ap-northeast-2

cd /opt/team1-app
docker compose ps
# back 은 blue-green(back-blue/back-green) — 지금 active 인 쪽은 conf.d/active-backend.conf 로 확인.
grep back nginx/conf.d/active-backend.conf
docker compose logs -f --tail=100 back-blue    # 또는 back-green, 위에서 확인한 쪽
docker compose logs --tail=50 nginx
journalctl -u team1-deploy-poller -n 50 --no-pager   # 배포 폴러
docker stats --no-stream          # 메모리 압박 확인 (4GB 박스)
free -h; swapon --show
```

### 6-1. SSH 예외 접속 (Q14 추가결정)

IAM 을 나눠줄 수 없어 SSM 을 못 쓰는 운영자 1인 전용. 그 외에는 위 SSM 을 쓴다.

**최초 1회 설정 (인프라 담당자가):**

1. 그 사람에게 키쌍 생성 요청 — `ssh-keygen -t ed25519 -C team1-ops -f ~/.ssh/team1` .
   `-C` 는 이름 대신 `team1-ops` 같은 중립 문자열로. 공개키(`team1.pub`)만 전달받는다.
2. 그 사람 공인 IP 확인 (`curl ifconfig.me`), `infra/terraform/terraform.tfvars` 에:
   ```hcl
   ssh_allowed_cidrs = ["<그사람-IP>/32"]
   ```
   `terraform apply` — SG 22 규칙만 라이브 추가, 인스턴스 재시작 없음.
3. 공개키를 인스턴스 `authorized_keys` 에 등록 (SSM 으로):
   ```bash
   aws ssm start-session --target <instance-id> --region ap-northeast-2
   sudo -u ec2-user tee -a /home/ec2-user/.ssh/authorized_keys <<'KEY'
   ssh-ed25519 AAAA... team1-ops
   KEY
   ```

**접속 (그 사람이):** `ssh -i ~/.ssh/team1 ec2-user@<EIP>`

**IP 가 바뀌면:** `terraform.tfvars` 의 `/32` 갱신 → `terraform apply`. 키는 그대로.

**인스턴스 재빌드 시:** `authorized_keys` 는 새 볼륨이라 3번을 다시 한다 (부트스트랩에 안 박음).

---

## 7. 트러블슈팅

| 증상 | 확인 |
|---|---|
| 배포 실패 (health check failed) | `docker compose logs back-blue`/`back-green`(배포 대상 색) — Flyway/DB 연결/OOM. deploy.sh 는 실패 시 active 색을 안 건드리므로 서비스는 안 끊김 |
| `back-blue`/`back-green` 계속 재시작 | `docker stats` 메모리, `-Xmx` 초과? `.env` DB 값? ffmpeg 겹침이면 아래 참고 |
| `back-blue`/`back-green` OOM-kill 반복 (인코딩 중) | 동시성 1 확인. 2회 이상이면 사이드카 분리 검토 — `infra-design.md` Q24 "ffmpeg 인코딩 확장 사다리" |
| 502 from Cloudflare | nginx up? `certs/origin.*` 존재? `docker compose logs nginx` |
| 526 (invalid SSL) from Cloudflare | Origin CA 인증서 만료/불일치, SSL 모드 Full(strict) 확인 |
| ffmpeg 중 앱 느려짐 | 정상 (동시성 1, swap 사용). 지속되면 인코딩을 새벽으로 이동 |
| 4시 배치 안 돎 | 인스턴스 running? 그 시각 재부팅 있었나(CloudWatch 알람 이력)? back 로그 |
| verify 타임아웃 (배포 안 됨) | 2장 "verify 가 타임아웃되면" — `journalctl -u team1-deploy-poller` |
| 폴러가 아예 안 돎 | `systemctl list-timers` 에 `team1-deploy-poller.timer` 있나? `/opt/team1-app/deploy-poller.sh`·`.env` 있나(ConditionPathExists)? `team1-app` active·`.deploy-paused` 없음? |
| SSM 세션 안 열림 | 인스턴스 running? SSM 에이전트? IAM 역할(`team1-app-role`) 붙었나 |

---

## 8. 정리 (프로젝트 종료 시)

```bash
cd infra/terraform && terraform destroy
```

- Cloudflare Workers 프로젝트 삭제, 도메인 갱신 해제(자동갱신 off).
- GHCR 패키지 삭제.
