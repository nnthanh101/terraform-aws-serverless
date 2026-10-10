# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# single-account: one account holds dev and production. An account administrator applies it once
# from their own terminal with a local backend, then moves the state into the bucket it created
# (backend.tf.example). terraform validate needs no credentials; plan and apply do.

terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28, < 7.0"
    }
  }
}

# The provider refuses any other account; the module also stops the plan on a wrong account or Region.
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = var.tags
  }
}

module "bootstrap" {
  source = "../.."

  account_id          = var.account_id
  region              = var.region
  github_repositories = var.github_repositories
  default_branch      = var.default_branch
  budget_limit_usd    = var.budget_limit_usd
  notification_email  = var.notification_email
  change_id           = var.change_id

  # One account for dev and production: dev is denied production resources, state and saved plans.
  account_mode            = "single"
  environments            = ["dev", "production"]
  production_environments = ["production"]

  # The same map as default_tags, so the module adds no lower-case copy of a key it already carries.
  tags = var.tags
}
