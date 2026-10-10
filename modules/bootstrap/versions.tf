# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Derived from the terraform-aws plugin's bootstrap template. See NOTICE.txt.
# ADR-003: terraform >= 1.11; aws >= 6.28, < 7.0. The caller configures the provider.

terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28, < 7.0"
    }
  }

  provider_meta "aws" {
    user_agent = [
      "registry.terraform.io/nnthanh101/serverless/aws"
    ]
  }
}
