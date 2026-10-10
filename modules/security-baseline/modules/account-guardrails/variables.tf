# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
variable "create_s3_public_access_block" {
  type        = bool
  description = "Create the account-level S3 public access block (all four settings on)."
  default     = true
}

variable "create_password_policy" {
  type        = bool
  description = "Create the IAM account password policy."
  default     = true
}

variable "create_ebs_encryption" {
  type        = bool
  description = "Turn on EBS encryption by default in each Region."
  default     = true
}

variable "create_snapshot_block" {
  type        = bool
  description = "Block public sharing of EBS snapshots in each Region."
  default     = true
}

variable "create_ami_block" {
  type        = bool
  description = "Block new public sharing of AMIs in each Region."
  default     = true
}

variable "create_imds_defaults" {
  type        = bool
  description = "Set the instance metadata defaults (IMDSv2 and hop limit) in each Region."
  default     = true
}

variable "account_id" {
  type        = string
  description = "The 12-digit ID of the account these settings apply to. The plan fails when the provider signs in to a different account."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be exactly 12 digits."
  }
}

variable "regions" {
  type        = list(string)
  description = "Regions that get the per-Region settings. Pass the same allowed Regions the organization allows. Each Region must be enabled in the account."

  validation {
    condition     = length(var.regions) >= 1
    error_message = "regions must hold at least one Region."
  }

  validation {
    condition     = alltrue([for r in var.regions : can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", r))])
    error_message = "Every entry in regions must look like ap-southeast-2."
  }

  validation {
    condition     = length(var.regions) == length(distinct(var.regions))
    error_message = "regions must not repeat a Region."
  }
}

variable "password_minimum_length" {
  type        = number
  description = "Minimum IAM password length."
  default     = 14

  validation {
    condition     = var.password_minimum_length >= 14 && var.password_minimum_length <= 128
    error_message = "password_minimum_length must be between 14 and 128."
  }
}

variable "snapshot_block_public_access" {
  type        = string
  description = "EBS snapshot public-access block per Region: block-all-sharing or block-new-sharing. Unblocked is refused."
  default     = "block-all-sharing"

  validation {
    condition     = contains(["block-all-sharing", "block-new-sharing"], var.snapshot_block_public_access)
    error_message = "snapshot_block_public_access must be block-all-sharing or block-new-sharing."
  }
}

variable "imds_v2_required" {
  type        = bool
  description = "Require IMDSv2 for new instances in each Region. False sets no-preference."
  default     = true
}

variable "imds_hop_limit" {
  type        = number
  description = "Default instance metadata hop limit. 2 lets containers on an instance reach IMDSv2."
  default     = 2

  validation {
    condition     = var.imds_hop_limit >= 1 && var.imds_hop_limit <= 64
    error_message = "imds_hop_limit must be between 1 and 64."
  }
}
