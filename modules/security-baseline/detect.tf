# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Detectors, each a switch that is off by default because each adds a monthly charge, and the
# EventBridge rules that send their findings to the alerts topic. Home Region only.

# ------------------------------------------------------------------ GuardDuty

resource "aws_guardduty_detector" "this" {
  # checkov:skip=CKV2_AWS_3:0024 one account in its home Region by design; enabling GuardDuty for an organization belongs to the landing zone
  count                        = var.guardduty_enabled ? 1 : 0
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_detector_feature" "this" {
  for_each    = toset(var.guardduty_enabled ? ["S3_DATA_EVENTS", "EBS_MALWARE_PROTECTION"] : [])
  detector_id = aws_guardduty_detector.this[0].id
  name        = each.value
  status      = "ENABLED"
}

# ------------------------------------------------------------------ Security Hub

# Only the AWS Foundational Security Best Practices standard, with consolidated control findings.
resource "aws_securityhub_account" "this" {
  count                     = var.security_hub_enabled ? 1 : 0
  enable_default_standards  = false
  control_finding_generator = "SECURITY_CONTROL"
  auto_enable_controls      = true

  depends_on = [aws_config_configuration_recorder_status.this]
}

resource "aws_securityhub_standards_subscription" "foundational" {
  count         = var.security_hub_enabled ? 1 : 0
  standards_arn = "arn:${local.partition}:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.this]
}

# ------------------------------------------------------------------ Config

# The recorder uses AWS Config's service-linked role, which Security Hub control Config.1 checks for.
# That role cannot write to S3 or use KMS, so Config delivers as config.amazonaws.com instead, which
# the trail bucket policy and the key policy allow for this account only. An account that already has
# AWSServiceRoleForConfig (from the console or another stack) imports it before the first apply:
#   terraform import 'module.baseline.aws_iam_service_linked_role.config[0]' \
#     arn:aws:iam::<account>:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig
resource "aws_iam_service_linked_role" "config" {
  count            = var.config_enabled ? 1 : 0
  aws_service_name = "config.amazonaws.com"
}

# Every supported resource type, including the global ones (IAM), recorded in the home Region only.
# Daily recording costs less than continuous; change-triggered controls then see changes once a day.
resource "aws_config_configuration_recorder" "this" {
  count    = var.config_enabled ? 1 : 0
  name     = local.prefix
  role_arn = local.config_role_arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }

  recording_mode {
    recording_frequency = "DAILY"
  }

  depends_on = [aws_iam_service_linked_role.config]
}

resource "aws_config_delivery_channel" "this" {
  count          = var.config_enabled ? 1 : 0
  name           = local.prefix
  s3_bucket_name = aws_s3_bucket.trail.bucket
  s3_key_prefix  = "config"
  s3_kms_key_arn = local.kms_arn

  depends_on = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.trail, aws_kms_key.this]
}

resource "aws_config_configuration_recorder_status" "this" {
  count      = var.config_enabled ? 1 : 0
  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

# ------------------------------------------------------------------ Inspector

resource "aws_inspector2_enabler" "this" {
  count          = var.inspector_enabled ? 1 : 0
  account_ids    = [var.account_id]
  resource_types = var.inspector_resource_types
}

# ------------------------------------------------------------------ findings to the alerts topic

locals {
  finding_rules = merge(
    var.guardduty_enabled ? {
      guardduty-findings = {
        description = "GuardDuty findings of severity 7 or more (high and critical)"
        pattern = jsonencode({
          source        = ["aws.guardduty"]
          "detail-type" = ["GuardDuty Finding"]
          detail        = { severity = [{ numeric = [">=", 7] }] }
        })
      }
    } : {},
    # The rule is always on: it matches findings of any analyzer in the Region, this module's or an existing one.
    {
      access-analyzer-findings = {
        description = "Access Analyzer findings about resources shared outside the account"
        pattern = jsonencode({
          source        = ["aws.access-analyzer"]
          "detail-type" = ["Access Analyzer Finding"]
          detail        = { status = ["ACTIVE"] }
        })
      }
    },
    var.security_hub_enabled ? {
      securityhub-findings = {
        description = "New, active Security Hub findings of critical or high severity"
        pattern = jsonencode({
          source        = ["aws.securityhub"]
          "detail-type" = ["Security Hub Findings - Imported"]
          detail = {
            findings = {
              Severity    = { Label = ["CRITICAL", "HIGH"] }
              Workflow    = { Status = ["NEW"] }
              RecordState = ["ACTIVE"]
            }
          }
        })
      }
    } : {},
  )
}

resource "aws_cloudwatch_event_rule" "findings" {
  for_each      = local.finding_rules
  name          = "${local.prefix}-${each.key}"
  description   = each.value.description
  event_pattern = each.value.pattern
}

resource "aws_cloudwatch_event_target" "findings" {
  for_each  = aws_cloudwatch_event_rule.findings
  rule      = each.value.name
  target_id = "alerts-topic"
  arn       = aws_sns_topic.alerts.arn
}
