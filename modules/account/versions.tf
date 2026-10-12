# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# The caller configures the aws provider: its assume_role into the member account, allowed_account_ids and
# default_tags. This module declares no provider block. Constraints match the root versions.tf (ADR-003), which scripts/validate-version-sync.sh enforces.
terraform {
  # Validations that read other variables need 1.9; S3-native state locking (the caller's backend) needs 1.11.
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      # Per-resource region (default VPCs, quota, Resource Explorer in each allowed Region) needs provider 6.
      source  = "hashicorp/aws"
      version = ">= 6.28, < 7.0"
    }
  }
}
