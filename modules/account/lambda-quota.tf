# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Lambda concurrent executions for this account. Off by default (0).
resource "aws_servicequotas_service_quota" "lambda_concurrency" {
  count        = var.lambda_concurrency_quota > 0 ? 1 : 0
  region       = var.region
  service_code = "lambda"
  quota_code   = "L-B99A9384"
  value        = var.lambda_concurrency_quota
}
