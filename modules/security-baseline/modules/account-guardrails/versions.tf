# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    aws = {
      # 6.x added the per-resource region argument used for the per-Region settings; 6.28 is the library floor.
      source  = "hashicorp/aws"
      version = ">= 6.28, < 7.0"
    }
  }
}
