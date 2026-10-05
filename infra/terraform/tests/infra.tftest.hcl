# `terraform test` — AWS 자격증명 없이 plan 단계에서만 검증한다.
# mock_provider 로 프로바이더 응답을 가짜로 채우므로 실제 리소스 생성·비용·네트워크가 없다.
# 실행: infra/terraform 에서 `terraform init -backend=false && terraform test`
#
# 각 run 블록은 "이 설정이 깨지면 무슨 사고가 나는가"를 error_message 에 적었다.

mock_provider "aws" {}
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
  cloudflare_zone_id   = "test-zone-id"
  cloudflare_api_token = "test-token"
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

  # 기본값(ssh_allowed_cidrs=[])이면 SSH 규칙이 0개여야 한다 (SSM 전용 = 원래 설계).
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.ssh_operator) == 0
    error_message = "ssh_allowed_cidrs 를 안 줬는데 22 규칙이 생겼다. 기본은 SSH 미개방이어야 한다."
  }
}

# -----------------------------------------------------------------------------
run "ssh_exception_is_narrow" {
  command = plan

  variables {
    ssh_allowed_cidrs = ["203.0.113.7/32"]
  }

  # 막는 사고: 예외 SSH 를 열되 포트가 22 아님 / 와일드카드로 넓힘 → 오리진 전면 노출.
  assert {
    condition = alltrue([
      for r in values(aws_vpc_security_group_ingress_rule.ssh_operator) :
      r.from_port == 22 && r.to_port == 22 && r.ip_protocol == "tcp" &&
      r.cidr_ipv4 != "0.0.0.0/0" && r.cidr_ipv4 != "::/0" && endswith(r.cidr_ipv4, "/32")
    ])
    error_message = "SSH 예외 규칙이 22/tcp·단일 호스트(/32) 조건을 벗어났다 (design Q14 추가결정)."
  }
}

# -----------------------------------------------------------------------------
run "instance_is_hardened_and_cheap" {
  command = plan

  # 막는 사고: 누가 instance_type 을 m5.large 등으로 올림 → 결재 없이 생성 불가 + 예산 초과.
  assert {
    condition     = can(regex("^t3a[.]", aws_instance.app.instance_type))
    error_message = "인스턴스 타입이 t3a(x86 버스터블) 계열이 아니다. medium 초과는 결재 필요, 월 8만원 예산도 위험 (design Q3)."
  }

  # 막는 사고: 누가 metadata_options 를 지움 → IMDSv1 허용 → SSRF 한 방으로 인스턴스 역할 크레덴셜 탈취.
  assert {
    condition     = aws_instance.app.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 가 강제되지 않는다. SSRF 취약점 하나로 SSM 역할 자격증명이 유출될 수 있다."
  }

  # 막는 사고: 누가 encrypted 를 뺌 → 루트 볼륨이 평문 → 유출 시 DB·미디어 임시파일 노출.
  assert {
    condition     = aws_instance.app.root_block_device[0].encrypted == true
    error_message = "루트 EBS 가 암호화되지 않는다. 볼륨 유출 시 평문."
  }

  # 막는 사고: 누가 true 로 되돌림 → 부트스트랩 스크립트 한 줄만 고쳐도 인스턴스 재생성
  #           → 수동 배치한 .env / Origin CA 인증서 / 리포 clone 전부 날아가고 서비스 다운.
  assert {
    condition     = aws_instance.app.user_data_replace_on_change == false
    error_message = "user_data_replace_on_change 가 true 다. bootstrap 수정이 인스턴스를 재생성해 .env/certs/src 를 유실시킨다 (runbook 1-4 재실행 필요)."
  }

  # 막는 사고: 누가 iam_instance_profile 를 뗌 → SSM 에이전트가 등록 안 됨 → 셸 접속 불가.
  assert {
    condition     = aws_instance.app.iam_instance_profile != ""
    error_message = "인스턴스에 IAM 프로파일이 없다. SSM Session 이 안 되면 유일한 셸 접속 경로가 사라진다 (22 미개방)."
  }
}

# -----------------------------------------------------------------------------
run "hung_instance_auto_reboots" {
  command = plan

  # 막는 사고: 24시간 가동 중 OS 무응답이 방치됨.
  assert {
    condition     = aws_cloudwatch_metric_alarm.instance_reboot.metric_name == "StatusCheckFailed_Instance"
    error_message = "자동 재부팅 알람이 인스턴스 상태 검사(StatusCheckFailed_Instance)를 보지 않는다."
  }

  assert {
    condition     = contains(aws_cloudwatch_metric_alarm.instance_reboot.alarm_actions, "arn:aws:automate:${var.aws_region}:ec2:reboot")
    error_message = "알람 액션이 EC2 reboot 이 아니다. 무응답 인스턴스가 자동 복구되지 않는다."
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

  assert {
    condition     = alltrue([for r in cloudflare_record.grafana : r.proxied == true])
    error_message = "grafana 레코드가 proxied 가 아니다. 오리진 IP 노출 + 보안그룹(CF IP only)과 충돌해 접속 불가."
  }
}

# -----------------------------------------------------------------------------
run "migration_test_records_only" {
  command = plan

  variables {
    api_subdomain     = "api-next"
    grafana_subdomain = ""
  }

  # 막는 사고: 이전 테스트 중 새 state 가 운영 레코드(api/grafana)를 만들어 옛 state 와 충돌.
  assert {
    condition     = cloudflare_record.api.name == "api-next" && length(cloudflare_record.grafana) == 0
    error_message = "테스트 설정(api-next, grafana 없음)에서 레코드 이름/개수가 기대와 다르다."
  }
}
