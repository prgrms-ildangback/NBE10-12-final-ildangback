variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "availability_zone" {
  description = "단일 퍼블릭 서브넷을 둘 AZ"
  type        = string
  default     = "ap-northeast-2a"
}

variable "name_prefix" {
  description = "리소스 이름 접두사 (계정 규칙: team1-<컴포넌트>)"
  type        = string
  default     = "team1"
}

variable "team_tag" {
  description = "모든 리소스에 붙는 필수 태그 값"
  type        = string
  default     = "devcos-team01"
}

variable "instance_type" {
  description = "EC2 타입. x86(t3a) 계열. small 은 즉시 허가, 그 이상은 결재 필요"
  type        = string
  default     = "t3a.medium"
}

variable "root_volume_size" {
  description = "루트 EBS(gp3) 크기 GiB. MySQL named volume + 미디어 임시파일 포함"
  type        = number
  default     = 30
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  type    = string
  default = "10.0.1.0/24"
}

# ---- SSH (예외 접속 1인용, Q14 추가결정) -------------------------------------
# 팀 AWS 계정이 IAM 을 나눠줄 수 없어 SSM 을 못 쓰는 운영자 1인에게만 22 를 연다.
# 기본값 [] = 규칙 0개(= SSM 전용, 원래 설계). 값을 채우면 그 CIDR 에서만 22 허용.
# 오리진 직접 노출이므로 반드시 /32 단위. 0.0.0.0/0 금지(tftest 가 차단).
variable "ssh_allowed_cidrs" {
  description = "SSH(22) 를 허용할 CIDR 목록. 운영자 공인 IP /32. 비우면 SSH 안 엶"
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.ssh_allowed_cidrs :
      c != "0.0.0.0/0" && c != "::/0" && can(regex("/32$", c))
    ])
    error_message = "ssh_allowed_cidrs 는 /32 단위만 허용한다. 0.0.0.0/0 은 금지 — 22 는 Cloudflare 뒤가 아니라 오리진 직접 노출이다."
  }
}

# ---- 도메인 / Cloudflare -------------------------------------------------------

variable "domain" {
  description = "루트 도메인. go-mmit.site 는 임시 placeholder — 구매 시 실제 값으로 교체"
  type        = string
  default     = "go-mmit.site"
}

variable "api_subdomain" {
  description = "백엔드 서브도메인 (앞부분만). apex 는 Cloudflare Pages 가 대시보드에서 관리"
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
  description = "Grafana 서브도메인 (앞부분만). apex/api 와 마찬가지로 Cloudflare 프록시 ON. 빈 값이면 레코드 없음"
  type        = string
  default     = "grafana"
}
