data "aws_ami" "al2023_x86_64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "app" {
  ami                    = data.aws_ami.al2023_x86_64.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.app.name

  user_data = file("${path.module}/../bootstrap/user-data.sh")
  # 스크립트를 나중에 고쳐도 인스턴스를 자동 재생성하지 않는다(수동 배치한 .env/certs/src 보호).
  # 부트스트랩을 다시 돌려야 하면 `terraform taint aws_instance.app` 후 apply + runbook 1-4 재실행.
  user_data_replace_on_change = false

  metadata_options {
    http_tokens   = "required" # IMDSv2 강제
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size
    encrypted   = true
    tags = {
      Name = "${var.name_prefix}-app-root"
    }
  }

  tags = { Name = "${var.name_prefix}-app" }

  lifecycle {
    # 새 AMI 가 나와도 인스턴스를 교체하지 않게.
    ignore_changes = [ami]
  }
}

# 계정 규칙: EIP 1개 허용. stop/start 후에도 IP 유지 목적.
resource "aws_eip" "app" {
  domain   = "vpc"
  instance = aws_instance.app.id
  tags     = { Name = "${var.name_prefix}-eip" }

  depends_on = [aws_internet_gateway.main]
}
