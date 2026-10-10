# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
terraform {
  # Import blocks with for_each need 1.7; validations that read other variables need 1.9.
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.28"
    }
  }
}

# One tenant's management account per run. The provider refuses any other account.
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
}
