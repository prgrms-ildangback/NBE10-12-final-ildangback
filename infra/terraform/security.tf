# 443 인바운드는 Cloudflare 서버 IP 대역만 허용한다(오리진 우회 차단, Q14).
# SSH(22) 는 열지 않는다. 셸 접속은 SSM.

# IPv4 대역만. 오리진(EC2)이 IPv4-only(VPC/서브넷/인스턴스에 IPv6 미구성, api 레코드도 EIP A 뿐)라
# Cloudflare 는 IPv4 로만 오리진에 접속한다. EC2 에 IPv6(AAAA)를 붙이는 날 ips-v6 대역을
# 이 블록과 대칭으로 추가할 것.
data "http" "cloudflare_ipv4" {
  url = "https://www.cloudflare.com/ips-v4"
}

locals {
  cloudflare_ipv4_cidrs = compact(split("\n", trimspace(data.http.cloudflare_ipv4.response_body)))
}

resource "aws_security_group" "app" {
  name        = "${var.name_prefix}-app-sg"
  description = "gommit app - 443 from Cloudflare only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-app-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "https_from_cloudflare" {
  for_each = toset(local.cloudflare_ipv4_cidrs)

  security_group_id = aws_security_group.app.id
  description       = "HTTPS from Cloudflare edge"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.app.id
  description       = "all outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
