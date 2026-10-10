# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# A consumer of the serverless-web-app submodule: a Lambda function behind an HTTP API, its files bucket, its signing key,
# alarms, and a web site on CloudFront. In your own repository write the registry form (shown below) instead of the path.
provider "aws" {
  region              = "ap-southeast-2"
  allowed_account_ids = ["123456789012"]
}

module "app" {
  # In your repository:
  #   source  = "nnthanh101/serverless/aws//modules/serverless-web-app"
  #   version = "0.1.0"
  # Here the path keeps the example testable before and after a release:
  source = "../../modules/serverless-web-app"

  account_id               = "123456789012"
  region                   = "ap-southeast-2"
  environment              = "dev"
  service                  = "shop"
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/platform-dev-workload-boundary"
  alarm_topic_arn          = "arn:aws:sns:ap-southeast-2:123456789012:alerts"

  source_dir      = "${path.module}/function"
  site_source_dir = "${path.module}/site"
}

output "site_url" {
  value = module.app.site_url
}

output "function_name" {
  value = module.app.function_name
}
