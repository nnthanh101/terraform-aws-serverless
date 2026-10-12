# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Account-wide settings that CIS and the AWS Foundational Security Best Practices ask for. They cost
# nothing. Block public access and the password policy are global; the EBS, snapshot, SSM and
# analyzer settings apply to the home Region.

# No forced expiry: NIST SP 800-63B advises against it, and no current CIS or FSBP check needs it.
resource "aws_iam_account_password_policy" "this" {
  # checkov:skip=CKV_AWS_9:0024 no forced password expiry, as the owner ruled: NIST SP 800-63B advises against it and no current CIS or FSBP control requires it
  minimum_password_length        = 14
  password_reuse_prevention      = 24
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
}

resource "aws_s3_account_public_access_block" "this" {
  account_id              = var.account_id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_ebs_encryption_by_default" "this" {
  enabled = true
}

resource "aws_ebs_snapshot_block_public_access" "this" {
  state = "block-all-sharing"
}

# SSM documents cannot be shared publicly from this account. The service setting API takes the full ARN.
resource "aws_ssm_service_setting" "document_public_sharing" {
  setting_id    = "arn:${local.partition}:ssm:${var.region}:${var.account_id}:servicesetting/ssm/documents/console/public-sharing-permission"
  setting_value = "Disable"
}

# Findings about resources shared outside the account; free for the ACCOUNT type.
# An account holds one ACCOUNT analyzer per Region; access_analyzer_enabled = false leaves the existing one in place.
resource "aws_accessanalyzer_analyzer" "this" {
  count         = var.access_analyzer_enabled ? 1 : 0
  analyzer_name = "${local.prefix}-access"
  type          = "ACCOUNT"
}

# The analyzer gained a count; this keeps an existing caller's state at the same object.
moved {
  from = aws_accessanalyzer_analyzer.this
  to   = aws_accessanalyzer_analyzer.this[0]
}

# No rules at all: nothing should use the default security group, and anything that does is refused.
resource "aws_default_security_group" "this" {
  count   = var.default_security_group_lockdown_enabled && length(data.aws_vpcs.default.ids) > 0 ? 1 : 0
  vpc_id  = data.aws_vpcs.default.ids[0]
  ingress = []
  egress  = []
}

# New instances in the home Region must use IMDSv2 tokens. Off by default so an existing caller plans no change.
# The precondition refuses a provider that signs in to another account than account_id.
data "aws_caller_identity" "current" {}

resource "aws_ec2_instance_metadata_defaults" "this" {
  for_each = var.imds_v2_required ? toset([var.region]) : toset([])

  http_put_response_hop_limit = 2
  http_tokens                 = "required"
  region                      = each.key

  lifecycle {
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id
      error_message = "The provider signs in to ${data.aws_caller_identity.current.account_id}, not account_id: check the provider alias."
    }
  }
}
