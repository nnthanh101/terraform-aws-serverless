# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# One encrypted topic for every alarm and finding of the account, with one email subscription.
# The workload roots' alarms may notify it too (their alarm_topic_arn), since it accepts any alarm of
# this account in the home Region.

resource "aws_sns_topic" "alerts" {
  name              = local.topic_name
  kms_master_key_id = local.kms_arn
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudWatchAlarmsPublish"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = local.topic_arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = var.account_id }
          ArnLike      = { "aws:SourceArn" = "${local.alarm_arn_prefix}*" }
        }
      },
      {
        Sid       = "EventBridgePublish"
        Effect    = "Allow"
        Principal = { Service = "events.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = local.topic_arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = var.account_id }
          ArnLike      = { "aws:SourceArn" = local.rule_arn_pattern }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "sns:Publish"
        Resource  = local.topic_arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        # The delivery pipeline and its workloads never delete, re-point or subscribe to the topic.
        Sid       = "DenyManagementByPipelineRoles"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["sns:DeleteTopic", "sns:SetTopicAttributes", "sns:AddPermission", "sns:RemovePermission", "sns:Subscribe"]
        Resource  = local.topic_arn
        Condition = { ArnLike = { "aws:PrincipalArn" = local.pipeline_principals } }
      },
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
