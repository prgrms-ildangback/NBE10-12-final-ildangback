# apex(go-mmit.site) = Cloudflare Pages. Cloudflare 가 apex 레코드를 자동 생성하므로 여기서는 관리하지 않는다.
# 여기서는 api / grafana 서브도메인만 관리한다. 이름은 변수(계정 이전 중엔 api-next, runbook 1-2).

resource "cloudflare_record" "api" {
  zone_id = var.cloudflare_zone_id
  name    = var.api_subdomain
  type    = "A"
  content = aws_eip.app.public_ip
  proxied = true # 오렌지 클라우드 — 엣지 TLS/DDoS. 오리진은 Origin CA 인증서로 Full(strict)
  ttl     = 1    # proxied 면 1(auto) 필수
  comment = "gommit backend (EC2). Managed by Terraform."
}

# 모니터링 UI
# 같은 EC2, nginx 안의 별도 vhost(grafana.conf)로 붙는다.
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
