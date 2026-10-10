# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# One AWS account, standardised and hardened, with no AWS Organizations: the state bucket (versioned, encrypted, public access
# blocked, TLS only), a monthly budget alarm, an audit trail in its own bucket, the IAM password policy, the account-wide S3
# public access block, EBS encryption and IMDSv2 by default, and GitHub OIDC plan and apply roles that trust ONE repository
# and its environments. It calls three submodules of this repository and holds no resource of its own.
#
# Apply it once from an administrator's terminal with a local backend, then move its state into the bucket it made.

locals {
  alert_email = coalesce(var.alert_email, var.notification_email)

  # The two protection policy names are unique per account, so a second baseline needs its own: the default
  # security_name_prefix keeps SecurityBaselineProtect, any other becomes CamelCase (kit-baseline -> KitBaselineProtect).
  protect_policy_prefix = var.security_name_prefix == "security-baseline-shared" ? "SecurityBaseline" : join("", [for w in split("-", var.security_name_prefix) : "${upper(substr(w, 0, 1))}${substr(w, 1, -1)}"])
}

module "bootstrap" {
  source = "../bootstrap"

  account_id = var.account_id
  region     = var.region

  github_repositories     = [var.github_repository]
  github_repository_ids   = var.github_repository_id == null ? [] : [var.github_repository_id]
  github_owner_id         = var.github_owner_id
  github_subject_prefixes = var.github_subject_prefix == null ? [] : [var.github_subject_prefix]
  default_branch          = var.default_branch

  name_prefix = var.name_prefix
  service     = var.service
  change_id   = var.change_id
  tags        = var.tags

  state_bucket_name    = var.state_bucket_name
  create_state_kms_key = var.create_state_kms_key

  budget_limit_usd   = var.budget_limit_usd
  notification_email = var.notification_email

  account_mode            = "single"
  environments            = var.environments
  production_environments = var.production_environments

  create_oidc_provider       = var.existing_oidc_provider_arn == null
  oidc_provider_arn          = var.existing_oidc_provider_arn
  enable_api_gateway_account = var.enable_api_gateway_account

  protect_security_baseline = true
  security_baseline_prefix  = var.security_name_prefix
}

module "security" {
  source = "../security-baseline"

  account_id  = var.account_id
  region      = var.region
  name_prefix = var.security_name_prefix
  alert_email = local.alert_email

  protect_policy_prefix     = local.protect_policy_prefix
  access_analyzer_enabled   = var.access_analyzer_enabled
  kms_key_enabled           = var.security_kms_key_enabled
  access_log_bucket_enabled = var.access_log_bucket_enabled
  log_retention_days        = var.log_retention_days

  trail_scope             = "account"
  ci_apply_role_names     = values(module.bootstrap.apply_role_names)
  pipeline_role_patterns  = ["${var.name_prefix}-*", "workload/*"]
  developer_environments  = [for e in var.environments : e if !contains(var.production_environments, e)]
  production_environments = var.production_environments
}

# The password policy, the S3 public access block and EBS encryption come from the security baseline above; this adds the one
# default it lacks, IMDSv2 for new instances, and leaves the other switches off so no setting has two owners.
module "guardrails" {
  source = "../security-baseline/modules/account-guardrails"

  account_id = var.account_id
  regions    = [var.region]

  create_s3_public_access_block = false
  create_password_policy        = false
  create_ebs_encryption         = false
  create_snapshot_block         = false
  create_ami_block              = false
  create_imds_defaults          = true
  imds_v2_required              = true
}
