output "instance_id" {
  description = "GitHub Actions Secret EC2_INSTANCE_ID 에 넣을 값"
  value       = aws_instance.app.id
}

output "public_ip" {
  description = "탄력적 IP. api/grafana 레코드가 가리킴"
  value       = aws_eip.app.public_ip
}

output "api_fqdn" {
  value = "${var.api_subdomain}.${var.domain}"
}

output "grafana_fqdn" {
  value = var.grafana_subdomain == "" ? null : "${var.grafana_subdomain}.${var.domain}"
}

output "deploy_role_arn" {
  description = "GitHub Actions Secret AWS_DEPLOY_ROLE_ARN 에 넣을 값"
  value       = aws_iam_role.deploy.arn
}

output "ec2_start_command" {
  value = "aws ec2 start-instances --instance-ids ${aws_instance.app.id} --region ${var.aws_region}"
}

output "ssm_session_command" {
  description = "기본 셸 접속 경로 (SSM). IAM 접근이 있는 사람용"
  value       = "aws ssm start-session --target ${aws_instance.app.id} --region ${var.aws_region}"
}
