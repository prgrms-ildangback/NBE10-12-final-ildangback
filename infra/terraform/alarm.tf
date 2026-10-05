# OS 무응답(메모리 고갈 등)으로 인스턴스 상태 검사가 실패하면 자동 재부팅.
resource "aws_cloudwatch_metric_alarm" "instance_reboot" {
  alarm_name        = "${var.name_prefix}-app-instance-check-reboot"
  alarm_description = "인스턴스 상태 검사 3분 연속 실패 시 재부팅"

  namespace   = "AWS/EC2"
  metric_name = "StatusCheckFailed_Instance"
  dimensions = {
    InstanceId = aws_instance.app.id
  }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  # 데이터 없음(정지 중 등)은 정상으로 본다.
  treat_missing_data = "notBreaching"

  alarm_actions = ["arn:aws:automate:${var.aws_region}:ec2:reboot"]
}
