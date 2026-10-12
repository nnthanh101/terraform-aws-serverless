# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# One AWS account, in or out of AWS Organizations: its state bucket and key, keyless CI plan and apply roles, and a monthly
# budget that emails the alert mailbox, from the library's own bootstrap module; optionally (security_baseline = true) the
# audit trail, alarms and account-wide hardening of security-baseline; and, for an Organizations member, the account-level
# settings (default VPCs, Lambda concurrency quota, Resource Explorer index). The calling root configures the aws provider
# (assume_role into a member account, allowed_account_ids, default_tags) and keeps the import block for the default
# internet gateways (default-vpcs.tf). A standalone account leaves the Organizations settings at their defaults.

locals {
  alert_email = coalesce(var.alert_email, var.notification_email)

  # The two protection policy names are unique per account, so a second baseline needs its own: the default
  # security_name_prefix keeps SecurityBaselineProtect, any other becomes CamelCase (kit-baseline -> KitBaselineProtect).
  protect_policy_prefix = var.security_name_prefix == "security-baseline-shared" ? "SecurityBaseline" : join("", [for w in split("-", var.security_name_prefix) : "${upper(substr(w, 0, 1))}${substr(w, 1, -1)}"])
}

module "bootstrap" {
  source = "../bootstrap"

  account_id                    = var.account_id
  region                        = var.region
  ci_platform                   = var.ci_platform
  ado_organization_id           = var.ado_organization_id
  ado_organization_name         = var.ado_organization_name
  ado_plan_service_connections  = var.ado_plan_service_connections
  ado_apply_service_connections = var.ado_apply_service_connections
  github_repositories           = var.github_repositories
  github_repository_ids         = var.github_repository_ids
  github_subject_prefixes       = var.github_subject_prefixes
  github_owner_id               = var.github_owner_id
  github_owner_ids              = var.github_owner_ids
  default_branch                = var.default_branch
  apply_workflow_refs           = var.apply_workflow_refs
  budget_limit_usd              = var.budget_limit_usd
  notification_email            = var.notification_email
  change_id                     = var.change_id
  service                       = var.service

  name_prefix          = var.name_prefix
  state_bucket_name    = var.state_bucket_name
  create_state_kms_key = var.create_state_kms_key

  create_oidc_provider       = var.existing_oidc_provider_arn == null
  oidc_provider_arn          = var.existing_oidc_provider_arn
  enable_api_gateway_account = var.enable_api_gateway_account

  # With security_baseline = false these are bootstrap's own defaults (true, "security-baseline"), so a member account's plan is unchanged.
  protect_security_baseline = true
  security_baseline_prefix  = var.security_baseline ? var.security_name_prefix : "security-baseline"

  account_mode            = var.account_mode
  environments            = var.environments
  production_environments = var.production_environments

  workload_boundary_extra_actions = var.workload_boundary_extra_actions
  passrole_services               = var.passrole_services
  container_repositories          = var.container_repositories

  # The same map as the caller's default_tags; a key here replaces the bootstrap module's own key of the same name.
  tags = var.tags
}

# The provider's allowed_account_ids already refuses any other account; these checks name the mistake in plain words
# and tie the state to the account. Terraform cannot read the backend key, so the key comes from the workspace: one
# workspace per member account, named after its ID.
data "aws_caller_identity" "current" {
  lifecycle {
    postcondition {
      condition     = self.account_id == var.account_id
      error_message = "Signed in to account ${self.account_id}, not the member account ${var.account_id}: the calling root's provider must assume a role in the member account."
    }
    postcondition {
      condition     = !var.require_account_workspace || terraform.workspace == var.account_id
      error_message = "The workspace is ${terraform.workspace}, not the member account ${var.account_id}: run terraform workspace select -or-create ${var.account_id} first, so this account's state is read and written under its own key."
    }
  }
}

# The account's security baseline: audit trail, alarms, password policy, S3 public access block, EBS encryption and IMDSv2.
# Off by default (an Organizations member gets these from the organization's controls).
module "security" {
  count  = var.security_baseline ? 1 : 0
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

  imds_v2_required = true
}

# The security module became optional (count) and IMDSv2 moved here from the retired guardrails module; the state keeps the same objects.
moved {
  from = module.security
  to   = module.security[0]
}

moved {
  from = module.guardrails.aws_ec2_instance_metadata_defaults.this
  to   = module.security[0].aws_ec2_instance_metadata_defaults.this
}
