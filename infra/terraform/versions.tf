terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.81"
    }
    cloudflare = {
      # v5 에서 cloudflare_record → cloudflare_dns_record 로 리소스명·속성이 바뀌었다.
      # 이 코드는 v4 스키마(cloudflare_record, content 속성) 기준.
      source  = "cloudflare/cloudflare"
      version = "~> 4.52"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # state backend: 로컬 (Q22). 담당자 1인만 apply, apply 후 팀 드라이브에 백업.
}
