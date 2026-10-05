output "instance_id" {
  description = "SSM 세션 대상"
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "탄력적 IP. Pages 도메인/네임서버와 무관, api 레코드가 자동으로 가리킴"
  value       = aws_eip.app.public_ip
}

output "api_fqdn" {
  value = "${var.api_subdomain}.${var.domain}"
}

output "grafana_fqdn" {
  description = "nginx Basic Auth(1차) + Grafana 로그인(2차) 통과해야 열람 가능"
  value       = var.grafana_subdomain == "" ? "(레코드 없음)" : "${var.grafana_subdomain}.${var.domain}"
}

output "ssm_start_command" {
  description = "수동으로 인스턴스를 켤 때"
  value       = "aws ec2 start-instances --instance-ids ${aws_instance.app.id} --region ${var.aws_region}"
}

output "ssm_session_command" {
  description = "기본 셸 접속 경로 (SSM). IAM 접근이 있는 사람용"
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}

output "ssh_command" {
  description = "SSM 을 못 쓰는 운영자 1인용. ssh_allowed_cidrs 를 채우고 런북대로 키 등록했을 때만 동작"
  value       = length(var.ssh_allowed_cidrs) > 0 ? "ssh ec2-user@${aws_eip.app.public_ip}" : "(ssh_allowed_cidrs 비어있음 — SSH 미개방)"
}
