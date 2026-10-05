variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_account_id" {
  description = "배포 대상 AWS 계정 ID (워크로드 프로젝트 계정)"
  type        = string
}

variable "availability_zone" {
  description = "단일 퍼블릭 서브넷을 둘 AZ"
  type        = string
  default     = "ap-northeast-2a"
}

variable "name_prefix" {
  description = "리소스 이름 접두사 (team1-<컴포넌트>)"
  type        = string
  default     = "team1"
}

variable "team_tag" {
  description = "모든 리소스에 붙는 필수 태그 값"
  type        = string
  default     = "devcos-team01"
}

variable "instance_type" {
  description = "EC2 타입. t3a 계열만 (tftest)"
  type        = string
  default     = "t3a.medium"
}

variable "root_volume_size" {
  description = "루트 EBS(gp3) 크기 GiB. MySQL named volume + 미디어 임시파일 포함"
  type        = number
  default     = 20
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

# ---- 도메인 / Cloudflare -------------------------------------------------------

variable "domain" {
  description = "루트 도메인 (Cloudflare Registrar 등록)"
  type        = string
  default     = "go-mmit.site"
}

variable "api_subdomain" {
  description = "백엔드 서브도메인 (앞부분만). 컷오버 전 테스트는 api-next"
  type        = string
  default     = "api"
}

variable "cloudflare_zone_id" {
  description = "Cloudflare 존 ID (대시보드 우측 하단)"
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API 토큰. Zone.DNS 편집 권한만 있으면 됨(api/grafana 레코드 관리)."
  type        = string
  sensitive   = true
}

# ---- 모니터링 (Q29) ------------------------------------------------------------

variable "grafana_subdomain" {
  description = "Grafana 서브도메인 (앞부분만). 빈 문자열이면 레코드 미생성(컷오버 전)"
  type        = string
  default     = "grafana"
}

# ---- GitHub Actions OIDC 배포 -----------------------------------------------

variable "github_repo" {
  description = "OIDC 신뢰 대상 리포지토리 (owner/name)"
  type        = string
  default     = "prgrms-ildangback/NBE10-12-final-ildangback"
}

variable "deploy_environment" {
  description = "deploy.yml 의 deploy job 이 도는 GitHub Environment 이름. OIDC sub 를 이 환경으로 한정한다."
  type        = string
  default     = "production"
}

# ---- Budget (크레딧 가드) ------------------------------------------------------

variable "alert_emails" {
  description = "Budget·알람 SNS 이메일 구독자"
  type        = list(string)
  validation {
    condition     = length(var.alert_emails) > 0
    error_message = "alert_emails 가 비면 Budget 정지·reboot 알림이 아무에게도 안 간다."
  }
}

variable "budget_start" {
  description = "크레딧 Budget 시작일 YYYY-MM-01 (계정 생성 월의 1일)"
  type        = string
  validation {
    condition     = can(regex("^\\d{4}-\\d{2}-01$", var.budget_start))
    error_message = "YYYY-MM-01 형식."
  }
}

variable "budget_limit_usd" {
  description = "크레딧 Budget 한도(USD). 예측 비용이 이 값을 넘으면 메일"
  type        = number
}

variable "budget_alert_usd" {
  description = "실제 누적 비용이 넘으면 메일을 보낼 금액(USD) 목록"
  type        = list(number)
}

variable "budget_stop_usd" {
  description = "누적 비용이 이 값(USD)을 넘으면 EC2 자동 stop"
  type        = number
  validation {
    condition     = var.budget_stop_usd > 0 && var.budget_stop_usd < var.budget_limit_usd
    error_message = "budget_stop_usd 는 0 초과, budget_limit_usd 미만. 정지 후에도 EBS/EIP 비용이 쌓인다."
  }
}
