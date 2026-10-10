# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      # The web ACL's per-resource region (us-east-1 for CloudFront) needs provider 6; 6.28 is the library floor.
      source  = "hashicorp/aws"
      version = ">= 6.28, < 7.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.7, < 3.0"
    }
    random = {
      # Ephemeral resources need 3.7.
      source  = "hashicorp/random"
      version = ">= 3.7, < 4.0"
    }
  }
}
