provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id] # 다른 계정 profile 로 apply 방지

  default_tags {
    tags = {
      Team    = var.team_tag
      Project = "gommit"
      Managed = "terraform"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
