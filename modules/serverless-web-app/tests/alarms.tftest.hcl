# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests of the alarms, with mocked providers. No AWS account or credentials are used.

mock_provider "aws" {}

mock_provider "archive" {}

variables {
  account_id               = "111122223333"
  region                   = "aa-example-1"
  environment              = "dev"
  service                  = "orders"
  permissions_boundary_arn = "arn:aws:iam::111122223333:policy/platform-dev-workload-boundary"
  alarm_topic_arn          = "arn:aws:sns:aa-example-1:111122223333:orders-dev-alarms"
  source_dir               = "build"
  site_source_dir          = "tests/fixtures/site"
}

run "alarms_for_this_mode" {
  command = plan

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.alarm) == 5
    error_message = "Every mode gets three function alarms and two alarms for its entry point."
  }

  assert {
    condition     = alltrue([for a in aws_cloudwatch_metric_alarm.alarm : startswith(a.alarm_name, "orders-dev-") && a.alarm_actions == toset([var.alarm_topic_arn])])
    error_message = "Every alarm must follow the naming rule and notify the alarm topic."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.alarm["lambda-duration-p95"].threshold == aws_lambda_function.app.timeout * 800
    error_message = "The duration alarm must fire at 80% of the function timeout."
  }
}

run "topic_is_required" {
  command = plan

  variables {
    alarm_topic_arn = "not-an-arn"
  }

  expect_failures = [var.alarm_topic_arn]
}
