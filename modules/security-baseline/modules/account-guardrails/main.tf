# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Account-level guardrails for one account. Call once per account with that account's provider.
# Per-Region settings use the resource-level region argument, so no provider alias is needed.
#
# Wrong-account check: every resource carries the same precondition (provider account equals
# account_id), so it is evaluated whenever ANY switch is on, whichever switch that is. A check on
# an output would depend on a caller reading it; a check on one resource would depend on its switch.
# With every switch off no resource exists, nothing is planned and nothing can land in an account.

data "aws_caller_identity" "current" {}

locals {
  regions          = toset(var.regions)
  provider_account = data.aws_caller_identity.current.account_id
}

resource "aws_s3_account_public_access_block" "this" {
  count = var.create_s3_public_access_block ? 1 : 0

  account_id = var.account_id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  lifecycle {
    precondition {
      condition     = local.provider_account == var.account_id
      error_message = "The provider signs in to ${local.provider_account}, not account_id: check the provider alias."
    }
  }
}

# No expiry: a rarely used break-glass user must not lock itself out (NIST SP 800-63B 5.1.1.2).
resource "aws_iam_account_password_policy" "this" {
  #checkov:skip=CKV_AWS_9: no expiry for a break-glass user, per NIST SP 800-63B
  count = var.create_password_policy ? 1 : 0

  allow_users_to_change_password = true
  hard_expiry                    = false
  max_password_age               = 0
  minimum_password_length        = var.password_minimum_length
  password_reuse_prevention      = 24
  require_lowercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  require_uppercase_characters   = true

  lifecycle {
    precondition {
      condition     = local.provider_account == var.account_id
      error_message = "The provider signs in to ${local.provider_account}, not account_id: check the provider alias."
    }
  }
}

resource "aws_ebs_encryption_by_default" "this" {
  for_each = var.create_ebs_encryption ? local.regions : toset([])

  enabled = true
  region  = each.key

  lifecycle {
    precondition {
      condition     = local.provider_account == var.account_id
      error_message = "The provider signs in to ${local.provider_account}, not account_id: check the provider alias."
    }
  }
}

resource "aws_ebs_snapshot_block_public_access" "this" {
  for_each = var.create_snapshot_block ? local.regions : toset([])

  region = each.key
  state  = var.snapshot_block_public_access

  lifecycle {
    precondition {
      condition     = local.provider_account == var.account_id
      error_message = "The provider signs in to ${local.provider_account}, not account_id: check the provider alias."
    }
  }
}

resource "aws_ec2_image_block_public_access" "this" {
  for_each = var.create_ami_block ? local.regions : toset([])

  region = each.key
  state  = "block-new-sharing"

  lifecycle {
    precondition {
      condition     = local.provider_account == var.account_id
      error_message = "The provider signs in to ${local.provider_account}, not account_id: check the provider alias."
    }
  }
}

resource "aws_ec2_instance_metadata_defaults" "this" {
  for_each = var.create_imds_defaults ? local.regions : toset([])

  http_put_response_hop_limit = var.imds_hop_limit
  http_tokens                 = var.imds_v2_required ? "required" : "no-preference"
  region                      = each.key

  lifecycle {
    precondition {
      condition     = local.provider_account == var.account_id
      error_message = "The provider signs in to ${local.provider_account}, not account_id: check the provider alias."
    }
  }
}
