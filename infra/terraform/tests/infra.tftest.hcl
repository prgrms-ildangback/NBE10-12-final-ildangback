# `terraform test` — AWS 자격증명 없이 plan 단계에서만 검증한다.
# mock_provider 로 프로바이더 응답을 가짜로 채우므로 실제 리소스 생성·비용·네트워크가 없다.
# 실행: infra/terraform 에서 `terraform init -backend=false && terraform test`
#
# 각 run 블록은 "이 설정이 깨지면 무슨 사고가 나는가"를 error_message 에 적었다.

mock_provider "aws" {
  # budget action execution_role_arn 형식 검증용
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/mock" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-northeast-2:123456789012:mock" }
  }
}
mock_provider "cloudflare" {}

# security.tf 의 data.http(Cloudflare IP 목록)를 가짜 3개 대역으로 대체.
mock_provider "http" {
  mock_data "http" {
    defaults = {
      response_body = "173.245.48.0/20\n103.21.244.0/22\n103.22.200.0/22\n"
      status_code   = 200
    }
  }
}

variables {
  aws_account_id       = "123456789012"
  cloudflare_zone_id   = "test-zone-id"
  cloudflare_api_token = "test-token"
  alert_emails         = ["test@example.com"]
  budget_start         = "2026-09-01"
  budget_limit_usd     = 100
  budget_alert_usd     = [50, 80]
  budget_stop_usd      = 95
}

# -----------------------------------------------------------------------------
run "security_group_locks_origin" {
  command = plan

  # 막는 사고: 누가 443 규칙의 포트/프로토콜을 바꿈.
  assert {
    condition = alltrue([
      for r in values(aws_vpc_security_group_ingress_rule.https_from_cloudflare) :
      r.from_port == 443 && r.to_port == 443 && r.ip_protocol == "tcp"
    ])
    error_message = "443 인그레스에 443/tcp 외 규칙이 섞였다."
  }

  # 막는 사고: 누가 cidr_ipv4 를 "0.0.0.0/0" 으로 바꿈 → Cloudflare 우회(엣지 DDoS/WAF 무력화).
  assert {
    condition = alltrue([
      for r in values(aws_vpc_security_group_ingress_rule.https_from_cloudflare) :
      r.cidr_ipv4 != "0.0.0.0/0" && r.cidr_ipv4 != "::/0"
    ])
    error_message = "인그레스에 0.0.0.0/0 이 있다. 443 은 Cloudflare IP 대역만 허용해야 오리진 우회를 막는다 (design Q14)."
  }
}

# -----------------------------------------------------------------------------
run "instance_is_hardened_and_cheap" {
  command = plan

  assert {
    condition     = can(regex("^t3a[.]", aws_instance.app.instance_type))
    error_message = "인스턴스 타입이 t3a 계열이 아니다. x86 이미지 불일치·크레딧 조기 소진 (design Q3)."
  }

  assert {
    condition     = aws_instance.app.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 가 강제되지 않는다. SSRF 취약점 하나로 SSM 역할 자격증명이 유출될 수 있다."
  }

  assert {
    condition     = aws_instance.app.root_block_device[0].encrypted == true
    error_message = "루트 EBS 가 암호화되지 않는다. 볼륨 유출 시 평문."
  }

  assert {
    condition     = aws_instance.app.user_data_replace_on_change == false
    error_message = "user_data_replace_on_change 가 true 다. bootstrap 수정이 인스턴스를 재생성해 .env/certs/src 를 유실시킨다 (runbook 1-4 재실행 필요)."
  }

  assert {
    condition     = aws_instance.app.iam_instance_profile != ""
    error_message = "인스턴스에 IAM 프로파일이 없다. SSM RunCommand/Session 이 안 되면 유일한 배포·접속 경로가 사라진다 (22 미개방)."
  }
}

# -----------------------------------------------------------------------------
run "credit_budget_stops_ec2" {
  command = plan

  assert {
    condition     = aws_budgets_budget.credit.cost_types[0].include_credit == false
    error_message = "Budget 이 크레딧 차감 후 비용을 본다. 크레딧 소진 전까지 $0 으로 보여 정지가 안 걸린다."
  }

  assert {
    condition     = aws_budgets_budget.credit.time_unit == "ANNUALLY"
    error_message = "Budget 이 연 누적이 아니다. 크레딧은 12개월 한 덩어리라 월 단위로는 소진을 못 잡는다."
  }

  assert {
    condition = (
      aws_budgets_budget_action.stop_ec2.approval_model == "AUTOMATIC" &&
      aws_budgets_budget_action.stop_ec2.action_threshold[0].action_threshold_value < var.budget_limit_usd &&
      aws_budgets_budget_action.stop_ec2.definition[0].ssm_action_definition[0].action_sub_type == "STOP_EC2_INSTANCES"
    )
    error_message = "EC2 자동 정지가 한도 미만·AUTOMATIC 이 아니다. 정지 후 EBS/EIP 비용까지 더하면 한도 초과."
  }
}

# -----------------------------------------------------------------------------
run "status_check_reboots_instance" {
  command = plan

  # 막는 사고: reboot 액션이 빠지거나 평가 기간이 늘어남 → OS 무응답이 방치돼 24시간 가동이 깨짐.
  assert {
    condition     = contains(aws_cloudwatch_metric_alarm.instance_reboot.alarm_actions, "arn:aws:automate:${var.aws_region}:ec2:reboot")
    error_message = "StatusCheckFailed 알람에 ec2:reboot 액션이 없다. OS 무응답 시 자동 복구가 안 된다."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.instance_reboot.evaluation_periods * aws_cloudwatch_metric_alarm.instance_reboot.period <= 300
    error_message = "reboot 까지 5분을 넘긴다. 무응답 시간이 그만큼 길어진다."
  }
}

# -----------------------------------------------------------------------------
run "deploy_oidc_is_environment_scoped" {
  # assume_role_policy 는 AWS 가 정규화해 plan 단계엔 unknown → apply(모의) 로 확정값 검사.
  command = apply

  # 막는 사고: 누가 sub 조건을 repo:<repo>:* 같은 와일드카드로 넓힘 → 아무 브랜치/태그/PR
  #           워크플로가 deploy-role 을 탈취해 ssm:SendCommand 로 EC2 임의 명령 실행 (design 보안 메모).
  assert {
    condition     = can(regex("repo:[^\"]+:environment:[^\"]+", aws_iam_role.deploy.assume_role_policy))
    error_message = "deploy-role 신뢰 정책 sub 가 GitHub Environment 로 한정돼 있지 않다. repo:<repo>:environment:<env> 형태여야 브랜치/PR 에서의 역할 탈취를 막는다."
  }

  assert {
    condition     = !can(regex("repo:[^\"]*:[*]", aws_iam_role.deploy.assume_role_policy))
    error_message = "deploy-role 신뢰 정책에 repo:...:* 와일드카드 sub 가 있다. 특정 environment 로 좁혀야 한다."
  }
}

# -----------------------------------------------------------------------------
run "api_dns_is_proxied" {
  command = plan

  # 막는 사고: proxied=false(그레이 클라우드) → EC2 공인 IP 가 DNS 로 그대로 노출
  #           → 보안그룹이 Cloudflare IP 만 허용하므로 사이트가 즉시 다운 + DDoS 무방비.
  assert {
    condition     = cloudflare_record.api.proxied == true
    error_message = "api 레코드가 proxied 가 아니다. 오리진 IP 노출 + 보안그룹(CF IP only)과 충돌해 접속 불가."
  }
}
