# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# A minimal caller: the provider, the module call, and the import the module cannot hold.
variable "account_id" {
  type        = string
  description = "The member account's 12-digit ID."
}

variable "region" {
  type        = string
  description = "The member account's Region. There is no default."
}

variable "management_account_id" {
  type        = string
  description = "The organization's management account; the module refuses default VPC changes there."
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"
    session_name = "member-account-bootstrap"
  }

  default_tags {
    tags = { service = "platform", change = "0067" }
  }
}

module "member_account" {
  source = "../.."

  account_id              = var.account_id
  region                  = var.region
  management_account_id   = var.management_account_id
  allowed_regions         = [var.region]
  default_vpcs            = "adopt"
  github_repositories     = ["acme/platform"]
  default_branch          = "develop"
  budget_limit_usd        = 100
  notification_email      = "alerts@example.com"
  change_id               = "0067"
  security_baseline       = false
  account_mode            = "landing-zone"
  environments            = ["sandbox"]
  production_environments = []
}

# An import block is allowed only in the root module, so the caller keeps it.
import {
  for_each = module.member_account.default_igw_ids
  to       = module.member_account.aws_internet_gateway.this[each.key]
  id       = "${each.value}@${each.key}"
}

output "backend_settings" {
  description = "The values for a workload root's backend.hcl in this account."
  value       = module.member_account.backend_settings
}
