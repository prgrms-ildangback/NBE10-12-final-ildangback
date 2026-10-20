# 크레딧 소진 가드. 크레딧 차감 전(VAT 포함) 누적 비용 기준.
# budget_stop_usd 에서 EC2 자동 stop. 반영 지연 + 정지 후 EBS/EIP 비용만큼 한도보다 낮게 둔다.

resource "aws_budgets_budget" "credit" {
  name              = "${var.name_prefix}-credit"
  budget_type       = "COST"
  limit_amount      = tostring(var.budget_limit_usd)
  limit_unit        = "USD"
  time_unit         = "ANNUALLY" # provider 5.x 는 CUSTOM 미지원. 생성 월 1일부터 12개월 누적
  time_period_start = "${var.budget_start}_00:00"

  cost_types {
    include_credit = false
  }

  dynamic "notification" {
    for_each = concat(
      [for usd in var.budget_alert_usd : { type = "ACTUAL", threshold = usd }],
      [{ type = "FORECASTED", threshold = var.budget_limit_usd }],
    )
    content {
      notification_type         = notification.value.type
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value.threshold
      threshold_type            = "ABSOLUTE_VALUE"
      subscriber_sns_topic_arns = [aws_sns_topic.alerts.arn]
    }
  }
}

resource "aws_budgets_budget_action" "stop_ec2" {
  budget_name        = aws_budgets_budget.credit.name
  action_type        = "RUN_SSM_DOCUMENTS"
  approval_model     = "AUTOMATIC"
  notification_type  = "ACTUAL"
  execution_role_arn = aws_iam_role.budget_action.arn

  action_threshold {
    action_threshold_type  = "ABSOLUTE_VALUE"
    action_threshold_value = var.budget_stop_usd
  }

  definition {
    ssm_action_definition {
      action_sub_type = "STOP_EC2_INSTANCES"
      instance_ids    = [aws_instance.app.id]
      region          = var.aws_region
    }
  }

  subscriber {
    address           = aws_sns_topic.alerts.arn
    subscription_type = "SNS"
  }
}

resource "aws_iam_role" "budget_action" {
  name = "${var.name_prefix}-budget-action-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "budgets.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.aws_account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:budgets::${var.aws_account_id}:budget/*" }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "budget_action" {
  role       = aws_iam_role.budget_action.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBudgetsActions_RolePolicyForResourceAdministrationWithSSM"
}
