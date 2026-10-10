# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
terraform {
  # 1.9 and later let a variable's validation read other variables; 1.11 is the library floor.
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      # The per-resource region of a CloudFront web ACL needs provider 6; 6.28 is the library floor.
      source  = "hashicorp/aws"
      version = ">= 6.28, < 7.0"
    }
  }
}
