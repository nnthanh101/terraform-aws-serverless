# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.

output "account_id" {
  description = "The account the plan ran in, checked against account_id."
  value       = data.aws_caller_identity.current.account_id
}

output "backend_settings" {
  description = "The values for a workload root's backend.hcl in this account."
  value       = module.bootstrap.backend_settings
}

output "plan_role_arns" {
  description = "The read-only roles for pull requests and the default branch, which price every change."
  value       = module.bootstrap.plan_role_arns
}

output "apply_role_arns" {
  description = "One apply role per environment, set as that GitHub Environment's role."
  value       = module.bootstrap.apply_role_arns
}

output "workload_boundary_policy_arns" {
  description = "The permissions boundary every workload role an apply role creates must carry, per environment."
  value       = module.bootstrap.workload_boundary_policy_arns
}

output "budget_name" {
  description = "The monthly budget, for the spend-alert proof."
  value       = module.bootstrap.budget_name
}

output "default_igw_ids" {
  description = "Internet gateway ID of the default VPC in each allowed Region when default_vpcs is adopt, else empty. The calling root imports each into aws_internet_gateway.this (an import block is allowed only in the root module)."
  value       = { for r, g in data.aws_internet_gateway.default : r => g.internet_gateway_id }
}

output "container_repository_urls" {
  description = "Repository URL per container_repositories name."
  value       = module.bootstrap.container_repository_urls
}

output "policy_documents" {
  description = "The trust, boundary and workload IAM documents of the roles, for review in the plan."
  value       = module.bootstrap.policy_documents
}

output "state_bucket_name" {
  description = "The state bucket."
  value       = module.bootstrap.state_bucket_name
}

output "oidc_provider_arn" {
  description = "The OIDC provider the roles trust: the one this module created, or existing_oidc_provider_arn."
  value       = module.bootstrap.oidc_provider_arn
}

output "apply_role_names" {
  description = "One apply role name per environment (<name_prefix>-apply-<environment>)."
  value       = module.bootstrap.apply_role_names
}

output "alerts_topic_arn" {
  description = "The SNS topic that receives the security alarms (alarm_topic_arn of every app in this account); null without security_baseline."
  value       = var.security_baseline ? module.security[0].alerts_topic_arn : null
}

output "trail_arn" {
  description = "The audit trail; null without security_baseline."
  value       = var.security_baseline ? module.security[0].trail_arn : null
}

output "trail_bucket_name" {
  description = "The bucket that holds the trail's log files; null without security_baseline."
  value       = var.security_baseline ? module.security[0].trail_bucket_name : null
}

output "protect_policy_names" {
  description = "The names of the two deny-only policies on the apply roles (SecurityBaselineProtect by default); null without security_baseline."
  value       = var.security_baseline ? module.security[0].protect_policy_names : null
}

output "controls" {
  description = "Which security controls this account has, one boolean each; null without security_baseline."
  value       = var.security_baseline ? module.security[0].controls : null
}

output "region_defaults" {
  description = "IMDS token mode; the other keys are null placeholders kept for existing readers. Null without security_baseline."
  value = var.security_baseline ? {
    (var.region) = {
      ebs_encryption = null
      snapshot_bpa   = null
      ami_bpa        = null
      imds_tokens    = module.security[0].imds_tokens
    }
  } : null
}
