# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# What the tenant's state settings and automation guardrail are filled from.
output "state_bucket_name" {
  description = "LZ_STATE_BUCKET."
  value       = module.bootstrap.state_bucket_name
}

output "state_region" {
  description = "LZ_STATE_REGION."
  value       = var.region
}

output "state_kms_key_arn" {
  description = "LZ_STATE_KMS_KEY_ARN."
  value       = module.bootstrap.state_kms_key_arn
}

output "backend_settings" {
  description = "The values for backend.hcl when this state moves into the bucket."
  value       = module.bootstrap.backend_settings
}

output "automation_guardrail_policy_json" {
  description = "Saved beside the tenant's settings as automation-guardrail.json and reviewed like code."
  value       = module.bootstrap.automation_guardrail_policy_json
}
