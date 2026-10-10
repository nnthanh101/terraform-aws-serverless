# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# A minimal caller: settings, the provider (allowed_account_ids, default_tags) and one module call.
variable "account_id" {
  type        = string
  description = "AWS account for this environment."
}

variable "region" {
  type        = string
  description = "AWS Region for this environment. There is no default."
}

variable "permissions_boundary_arn" {
  type        = string
  description = "This environment's entry in the bootstrap module's workload_boundary_policy_arns output."
}

variable "alarm_topic_arn" {
  type        = string
  description = "SNS topic that receives alarm notifications."
}

provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]

  default_tags {
    tags = { service = "orders", environment = "dev", change = "0067" }
  }
}

module "app" {
  source = "../.."

  account_id               = var.account_id
  region                   = var.region
  environment              = "dev"
  service                  = "orders"
  permissions_boundary_arn = var.permissions_boundary_arn
  alarm_topic_arn          = var.alarm_topic_arn

  # Paths resolve from where terraform runs.
  package_zip_path = "${path.root}/../../dist/api.zip"
  site_source_dir  = "${path.root}/../../site"

  environment_variables = {
    DATABASE_PATH = "app.db"
  }
}

output "site_url" {
  description = "HTTPS address of the static site."
  value       = module.app.site_url
}

output "url" {
  description = "HTTPS address of the API."
  value       = module.app.url
}
