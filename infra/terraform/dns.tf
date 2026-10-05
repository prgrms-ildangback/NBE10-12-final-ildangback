# apex 는 Workers 커스텀 도메인이 자동 생성. 여기서는 api/grafana 만.

resource "cloudflare_record" "api" {
  zone_id = var.cloudflare_zone_id
  name    = var.api_subdomain
  type    = "A"
  content = aws_eip.app.public_ip
  proxied = true # 오렌지 클라우드 — 엣지 TLS/DDoS. 오리진은 Origin CA 인증서로 Full(strict)
  ttl     = 1    # proxied 면 1(auto) 필수
  comment = "gommit backend (EC2). Managed by Terraform."
}

# 모니터링 UI (nginx grafana.conf). grafana_subdomain = "" 이면 미생성
resource "cloudflare_record" "grafana" {
  count   = var.grafana_subdomain == "" ? 0 : 1
  zone_id = var.cloudflare_zone_id
  name    = var.grafana_subdomain
  type    = "A"
  content = aws_eip.app.public_ip
  proxied = true # 오렌지 클라우드 — 엣지 TLS/DDoS. 인증은 오리진(nginx Basic Auth)에서
  ttl     = 1
  comment = "gommit grafana (EC2, nginx Basic Auth). Managed by Terraform."
}
