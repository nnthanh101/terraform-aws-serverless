# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.

output "backend_settings" {
  description = "Values for the state backend of every root in this account (add key = \"<app>/<environment>/terraform.tfstate\")."
  value       = module.bootstrap.backend_settings
}

output "state_bucket_name" {
  description = "The state bucket."
  value       = module.bootstrap.state_bucket_name
}

output "oidc_provider_arn" {
  description = "The GitHub OIDC provider the roles trust: the one this module created, or existing_oidc_provider_arn."
  value       = module.bootstrap.oidc_provider_arn
}

output "plan_role_arns" {
  description = "Read-only plan roles: pr (pull requests) and default (the default branch, which saves the production plan)."
  value       = module.bootstrap.plan_role_arns
}

output "apply_role_arns" {
  description = "One apply role per environment; each trusts only its GitHub Environment."
  value       = module.bootstrap.apply_role_arns
}

output "apply_role_names" {
  description = "One apply role name per environment (<name_prefix>-apply-<environment>)."
  value       = module.bootstrap.apply_role_names
}

output "workload_boundary_policy_arns" {
  description = "The permissions boundary per environment: permissions_boundary_arn of that environment's app."
  value       = module.bootstrap.workload_boundary_policy_arns
}

output "alerts_topic_arn" {
  description = "The SNS topic that receives the security alarms: alarm_topic_arn of every app in this account."
  value       = module.security.alerts_topic_arn
}

output "trail_arn" {
  description = "The audit trail."
  value       = module.security.trail_arn
}

output "trail_bucket_name" {
  description = "The bucket that holds the trail's log files."
  value       = module.security.trail_bucket_name
}

output "protect_policy_names" {
  description = "The names of the two deny-only policies on the apply roles; they follow security_name_prefix (SecurityBaselineProtect by default)."
  value       = module.security.protect_policy_names
}

output "budget_name" {
  description = "The monthly account budget."
  value       = module.bootstrap.budget_name
}

output "controls" {
  description = "Which controls this account has, one boolean each."
  value       = module.security.controls
}

output "region_defaults" {
  description = "The per-Region defaults: EBS encryption and the IMDS token mode."
  value       = module.guardrails.settings
}
