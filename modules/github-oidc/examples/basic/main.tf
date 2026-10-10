# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# One repository may plan from any ref; the apply role trusts the main branch and the production environment.
# All values are placeholders; replace them with your own in a gitignored file.
terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.28"
    }
  }
}

variable "region" {
  type        = string
  description = "Region the provider calls AWS from."
}

provider "aws" {
  region = var.region
}

module "github_oidc" {
  source = "../.."

  github_org          = "example-org"
  github_repositories = ["example-repo"]

  apply_allowed_refs = ["ref:refs/heads/main", "environment:production"]

  # No default: grant the apply role only what the pipeline needs.
  apply_policy_arns = ["arn:aws:iam::aws:policy/AmazonS3FullAccess"]

  tags = {
    environment = "example"
    managed-by  = "terraform"
  }
}

output "plan_role_arn" {
  description = "Role ARN for the plan job."
  value       = module.github_oidc.plan_role_arn
}

output "apply_role_arn" {
  description = "Role ARN for the apply job."
  value       = module.github_oidc.apply_role_arn
}
