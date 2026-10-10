# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# The values a person copies into the repository variables and each workload root's backend.

output "backend_settings" {
  description = "Values for backend.tf here and envs/<env>.backend.hcl in each workload root."
  value       = module.bootstrap.backend_settings
}

output "plan_role_arns" {
  description = "Repository variables PLAN_PR_ROLE_ARN and PLAN_DEFAULT_ROLE_ARN."
  value       = module.bootstrap.plan_role_arns
}

output "apply_role_arns" {
  description = "Environment variables APPLY_ROLE_ARN_<ENV>."
  value       = module.bootstrap.apply_role_arns
}

output "workload_boundary_policy_arns" {
  description = "permissions_boundary_arn for each environment's workload root."
  value       = module.bootstrap.workload_boundary_policy_arns
}

output "automation_guardrail_policy_json" {
  description = "Inline policy for the automation's read-only permission sets."
  value       = module.bootstrap.automation_guardrail_policy_json
}
