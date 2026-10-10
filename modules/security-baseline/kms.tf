# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# One key for the trail files, the trail's log group and the alerts topic. Each service may use it
# only for this account's own trail, log group, alarms and rules. The delivery pipeline and its
# workload roles may not use or change it, whatever their own policies allow.

locals {
  key_statements = concat([
    {
      Sid       = "AccountAdministersKeyThroughIam"
      Effect    = "Allow"
      Principal = { AWS = "${local.iam_prefix}:root" }
      Action    = "kms:*"
      Resource  = "*"
    },
    {
      # The CloudTrail encryption context names the trail as aws:cloudtrail:arn.
      Sid       = "CloudTrailEncryptLogs"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "kms:GenerateDataKey*"
      Resource  = "*"
      Condition = {
        StringEquals = { "aws:SourceArn" = local.trail_arn }
        StringLike   = { "kms:EncryptionContext:aws:cloudtrail:arn" = "arn:${local.partition}:cloudtrail:*:${var.account_id}:trail/*" }
      }
    },
    {
      # The trail bucket uses an S3 Bucket Key, which CloudTrail decrypts when it writes.
      Sid       = "CloudTrailDecryptWithBucketKey"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "kms:Decrypt"
      Resource  = "*"
      Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
    },
    {
      Sid       = "CloudTrailDescribeKey"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "kms:DescribeKey"
      Resource  = "*"
      Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
    },
    {
      Sid       = "CloudWatchLogsUseKey"
      Effect    = "Allow"
      Principal = { Service = local.logs_via }
      Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
      Resource  = "*"
      Condition = { ArnEquals = { "kms:EncryptionContext:aws:logs:arn" = local.log_group_arn } }
    },
    {
      # Any alarm of this account in the home Region, so the workload roots' alarms can notify the topic too.
      Sid       = "CloudWatchAlarmsPublish"
      Effect    = "Allow"
      Principal = { Service = "cloudwatch.amazonaws.com" }
      Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
      Resource  = "*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = var.account_id }
        ArnLike      = { "aws:SourceArn" = "${local.alarm_arn_prefix}*" }
      }
    },
    {
      # KMS receives no source account or ARN from EventBridge when it publishes to an encrypted topic
      # (SNS developer guide, "Compatibility with AWS services"); the topic policy names the rules instead.
      Sid       = "EventBridgePublish"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
      Resource  = "*"
    },
    ], [for s in [{
      # AWS Config delivers as its service principal, for this account only (Config developer guide,
      # "Permissions for the KMS Key for the AWS Config Delivery Channel").
      Sid       = "ConfigDeliverSnapshots"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
      Resource  = "*"
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }] : s if var.config_enabled], [
    {
      Sid       = "DenyPipelineRoles"
      Effect    = "Deny"
      Principal = { AWS = "*" }
      Action = [
        "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion",
        "kms:Disable*", "kms:CreateGrant",
      ]
      Resource  = "*"
      Condition = { ArnLike = { "aws:PrincipalArn" = local.pipeline_principals } }
    },
  ])
}

resource "aws_kms_key" "this" {
  count                   = var.kms_key_enabled ? 1 : 0
  description             = "Encrypts the ${local.prefix} trail, its log group and the alerts topic"
  enable_key_rotation     = true
  rotation_period_in_days = 365
  deletion_window_in_days = 30
  policy                  = jsonencode({ Version = "2012-10-17", Statement = local.key_statements })

  # The organization's protect-security-logging guardrail denies disabling, deleting or re-tagging a key that carries this tag.
  tags = var.protected_key_tag == null ? {} : { (var.protected_key_tag.key) = var.protected_key_tag.value }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "this" {
  count         = var.kms_key_enabled ? 1 : 0
  name          = local.key_alias
  target_key_id = aws_kms_key.this[0].key_id
}

# The key and alias gained a count; these keep an existing caller's state at the same objects.
moved {
  from = aws_kms_key.this
  to   = aws_kms_key.this[0]
}

moved {
  from = aws_kms_alias.this
  to   = aws_kms_alias.this[0]
}
