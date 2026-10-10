# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# What the delivery repository's GitHub Environments and backend are filled from.
output "backend_settings" {
  description = "The values for backend.hcl when this state moves into the bucket."
  value       = module.bootstrap.backend_settings
}

output "plan_role_arns" {
  description = "The read-only roles for pull requests and the default branch."
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
