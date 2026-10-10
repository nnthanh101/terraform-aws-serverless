# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Account security baseline. A multi-Region trail into an encrypted bucket and log group, the CIS
# CloudWatch alarms and a dashboard, one alerts topic, account-level settings, the people roles, and
# a protection policy that denies the delivery roles each direct way to switch any of it off. GuardDuty,
# Security Hub, Config, Inspector and a web ACL are switches, off by default, because each adds a monthly charge.
# Regional controls sit in the home Region only; the multi-Region trail and the alarms on its log
# group still see every enabled Region, and a trail whose home Region is opt-in still receives
# global service events.

data "aws_partition" "current" {}

# Read only for an organization trail, which needs the organization ID and the management account.
data "aws_organizations_organization" "this" {
  count = local.org_trail ? 1 : 0
}

# The home Region's default VPC, when the account still has one: its default security group is emptied.
data "aws_vpcs" "default" {
  filter {
    name   = "isDefault"
    values = ["true"]
  }
}

locals {
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix
  prefix     = var.name_prefix
  org_trail  = var.trail_scope == "organization"
  iam_prefix = "arn:${local.partition}:iam::${var.account_id}"
  s3_via     = "s3.${var.region}.${local.dns_suffix}"
  logs_via   = "logs.${var.region}.${local.dns_suffix}"

  # Every name and ARN is built from strings, so the policies that name them are complete at plan.
  trail_name            = "${local.prefix}-trail"
  trail_arn             = "arn:${local.partition}:cloudtrail:${var.region}:${var.account_id}:trail/${local.trail_name}"
  trail_bucket          = "${local.prefix}-trail-${var.account_id}"
  trail_bucket_arn      = "arn:${local.partition}:s3:::${local.trail_bucket}"
  access_log_bucket     = "${local.prefix}-access-logs-${var.account_id}"
  access_log_bucket_arn = "arn:${local.partition}:s3:::${local.access_log_bucket}"
  log_group_name        = "${local.prefix}-cloudtrail"
  log_group_arn         = "arn:${local.partition}:logs:${var.region}:${var.account_id}:log-group:${local.log_group_name}"
  topic_name            = "${local.prefix}-alerts"
  topic_arn             = "arn:${local.partition}:sns:${var.region}:${var.account_id}:${local.topic_name}"
  key_alias             = "alias/${local.prefix}"
  key_alias_arn         = "arn:${local.partition}:kms:${var.region}:${var.account_id}:${local.key_alias}"
  dashboard_name        = "${local.prefix}-overview"
  alarm_arn_prefix      = "arn:${local.partition}:cloudwatch:${var.region}:${var.account_id}:alarm:"
  rule_arn_pattern      = "arn:${local.partition}:events:${var.region}:${var.account_id}:rule/${local.prefix}-*"
  web_acl_name          = "${local.prefix}-web"
  web_acl_region        = var.waf_scope == "CLOUDFRONT" ? "us-east-1" : var.region
  protect_policy_names  = ["${var.protect_policy_prefix}Protect", "${var.protect_policy_prefix}ProtectWebAcl"]
  protect_policy_arns   = [for n in local.protect_policy_names : "${local.iam_prefix}:policy/security-baseline/${n}"]
  # AWS Config records with its service-linked role, as Security Hub control Config.1 expects.
  config_role_arn = "${local.iam_prefix}:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"

  # People roles exist only for the principals named; every ARN is known whether or not they do.
  break_glass_on    = length(var.break_glass_principal_arns) > 0
  people_on         = length(var.trusted_principal_arns) > 0
  people_role_names = ["BreakGlassAdmin", "SecurityAuditor", "DeveloperTemplate"]
  people_role_arns  = [for n in local.people_role_names : "${local.iam_prefix}:role/${n}"]
  break_glass_arn   = local.people_role_arns[0]
  access_log_on     = var.access_log_bucket_enabled
  kms_arn           = var.kms_key_enabled ? aws_kms_key.this[0].arn : null

  # The delivery pipeline and the workload roles it creates (templates/bootstrap names them gha-* and
  # workload/*). Resource policies deny them by aws:PrincipalArn, as the state bucket does.
  pipeline_principals = [for p in var.pipeline_role_patterns : "${local.iam_prefix}:role/${p}"]

  # The state bucket's settings list (templates/bootstrap main.tf): Requester Pays, Object Lock,
  # notifications, logging, inventory, replication and lifecycle stay with the person who applies this.
  bucket_settings = [
    "s3:DeleteBucket*", "s3:PutBucket*", "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration",
    "s3:PutReplicationConfiguration", "s3:PutInventoryConfiguration", "s3:PutAnalyticsConfiguration",
    "s3:PutMetricsConfiguration", "s3:PutIntelligentTieringConfiguration", "s3:PutAccelerateConfiguration",
    "s3:CreateBucketMetadata*", "s3:UpdateBucketMetadata*",
  ]
  # Writing, removing, re-permissioning or holding log files.
  log_object_writes = [
    "s3:PutObject", "s3:DeleteObject*", "s3:PutObjectAcl", "s3:PutObjectRetention", "s3:PutObjectLegalHold",
    "s3:BypassGovernanceRetention",
  ]

  controls = {
    trail                        = true
    guardduty                    = var.guardduty_enabled
    security_hub                 = var.security_hub_enabled
    config                       = var.config_enabled
    inspector                    = var.inspector_enabled
    waf                          = var.waf_enabled
    access_log_bucket            = local.access_log_on
    unauthorized_api_calls_alarm = var.unauthorized_api_calls_alarm_enabled
    break_glass_role             = local.break_glass_on
    people_roles                 = local.people_on
    access_analyzer              = var.access_analyzer_enabled
  }
}
