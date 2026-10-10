# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
output "account_id" {
  description = "The account the guardrails apply to."
  value       = var.account_id
}

output "regions" {
  description = "Regions that carry the per-Region settings."
  value       = sort(var.regions)
}

output "settings" {
  description = "Per Region: EBS default encryption, snapshot block state, AMI block state and IMDS token mode. A value is null when its switch is off."
  value = {
    for r in sort(var.regions) : r => {
      ebs_encryption = try(aws_ebs_encryption_by_default.this[r].enabled, null)
      snapshot_bpa   = try(aws_ebs_snapshot_block_public_access.this[r].state, null)
      ami_bpa        = try(aws_ec2_image_block_public_access.this[r].state, null)
      imds_tokens    = try(aws_ec2_instance_metadata_defaults.this[r].http_tokens, null)
    }
  }
}
