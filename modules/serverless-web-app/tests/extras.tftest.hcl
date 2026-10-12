# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests of extra_role_statements, files_lifecycle_rules and system_log_level, with mocked providers.

mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_resource "aws_apigatewayv2_api" {
    defaults = {
      id            = "a1b2c3d4e5"
      api_endpoint  = "https://a1b2c3d4e5.execute-api.aa-example-1.amazonaws.com"
      execution_arn = "arn:aws:execute-api:aa-example-1:111122223333:a1b2c3d4e5"
    }
  }

  mock_resource "aws_lambda_alias" {
    defaults = {
      arn        = "arn:aws:lambda:aa-example-1:111122223333:function:orders-dev-api:live"
      invoke_arn = "arn:aws:apigateway:aa-example-1:lambda:path/2015-03-31/functions/arn:aws:lambda:aa-example-1:111122223333:function:orders-dev-api:live/invocations"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:aa-example-1:111122223333:log-group:/aws/apigateway/orders-dev-api"
    }
  }

  mock_resource "aws_cloudfront_distribution" {
    defaults = {
      id          = "EDFDVBD6EXAMPLE"
      domain_name = "d111111abcdef8.cloudfront.net"
    }
  }
}

mock_provider "archive" {}

override_resource {
  target          = aws_s3_bucket.files
  override_during = plan
  values = {
    arn = "arn:aws:s3:::orders-dev-files-111122223333"
  }
}

override_resource {
  target          = aws_kms_key.files
  override_during = plan
  values = {
    arn    = "arn:aws:kms:aa-example-1:111122223333:key/11111111-1111-1111-1111-111111111111"
    key_id = "11111111-1111-1111-1111-111111111111"
  }
}

override_resource {
  target          = aws_secretsmanager_secret.secret_key
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:aa-example-1:111122223333:secret:orders-dev-secret-key-AbCdEf"
  }
}

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

run "defaults_change_nothing" {
  command = plan

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.files.policy).Statement) == 3 && length(aws_s3_bucket_lifecycle_configuration.files.rule) == 1
    error_message = "with the new inputs unset, the files policy keeps its three statements and the bucket its one rule"
  }

  assert {
    condition     = aws_lambda_function.app.logging_config[0].system_log_level == "WARN"
    error_message = "a null system_log_level keeps WARN"
  }
}

run "extra_statements_appear_with_conditions" {
  command = plan

  variables {
    extra_role_statements = [
      {
        sid       = "ReadCost"
        effect    = "Allow"
        actions   = ["ce:GetCostAndUsage"]
        resources = ["*"]
      },
      {
        sid       = "ApprovalsCreateOnly"
        effect    = "Deny"
        actions   = ["s3:PutObject"]
        resources = ["arn:aws:s3:::orders-dev-files-111122223333/approvals/*"]
        conditions = [{
          test     = "Null"
          variable = "s3:if-none-match"
          values   = ["true"]
        }]
      },
    ]
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.files.policy).Statement) == 5 &&
      jsondecode(aws_iam_role_policy.files.policy).Statement[3].Sid == "ReadCost" &&
      jsondecode(aws_iam_role_policy.files.policy).Statement[3].Resource == ["*"] &&
      !contains(keys(jsondecode(aws_iam_role_policy.files.policy).Statement[3]), "Condition")
    )
    error_message = "an Allow read on * is appended after the built-in statements, with no Condition"
  }

  assert {
    condition = (
      jsondecode(aws_iam_role_policy.files.policy).Statement[4].Effect == "Deny" &&
      jsondecode(aws_iam_role_policy.files.policy).Statement[4].Condition == { Null = { "s3:if-none-match" = ["true"] } }
    )
    error_message = "the Deny keeps its condition"
  }
}

run "refuses_bad_effect" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "allow", actions = ["s3:GetObject"], resources = ["arn:aws:s3:::b/*"] }]
  }
  expect_failures = [var.extra_role_statements]
}

run "refuses_duplicate_sid" {
  command = plan
  variables {
    extra_role_statements = [
      { sid = "A", effect = "Deny", actions = ["s3:PutObject"], resources = ["arn:aws:s3:::b/*"] },
      { sid = "A", effect = "Deny", actions = ["s3:DeleteObject"], resources = ["arn:aws:s3:::b/*"] },
    ]
  }
  expect_failures = [var.extra_role_statements]
}

run "refuses_iam_allow" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "Allow", actions = ["iam:PassRole"], resources = ["arn:aws:iam::111122223333:role/x"] }]
  }
  expect_failures = [var.extra_role_statements]
}

run "refuses_sts_allow" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "Allow", actions = ["sts:AssumeRole"], resources = ["arn:aws:iam::111122223333:role/x"] }]
  }
  expect_failures = [var.extra_role_statements]
}

run "refuses_service_wildcard_allow" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "Allow", actions = ["s3:*"], resources = ["arn:aws:s3:::b/*"] }]
  }
  expect_failures = [var.extra_role_statements]
}

run "refuses_star_action_allow" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "Allow", actions = ["*"], resources = ["arn:aws:s3:::b/*"] }]
  }
  expect_failures = [var.extra_role_statements]
}

run "refuses_write_on_star" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "Allow", actions = ["s3:PutObject"], resources = ["*"] }]
  }
  expect_failures = [var.extra_role_statements]
}

run "refuses_partial_wildcard_action" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "Allow", actions = ["s3:Put*"], resources = ["arn:aws:s3:::b/*"] }]
  }
  expect_failures = [var.extra_role_statements]
}

run "refuses_write_on_wildcard_arn" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "Allow", actions = ["s3:PutObject"], resources = ["arn:aws:s3:::*"] }]
  }
  expect_failures = [var.extra_role_statements]
}

run "refuses_secret_value_on_star" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "Allow", actions = ["secretsmanager:GetSecretValue"], resources = ["*"] }]
  }
  expect_failures = [var.extra_role_statements]
}

run "refuses_write_on_table_wildcard" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "Allow", actions = ["dynamodb:PutItem"], resources = ["arn:aws:dynamodb:ap-southeast-2:111111111111:table/*"] }]
  }
  expect_failures = [var.extra_role_statements]
}

run "allows_write_on_specific_prefix" {
  command = plan
  variables {
    extra_role_statements = [{ sid = "A", effect = "Allow", actions = ["s3:PutObject"], resources = ["arn:aws:s3:::orders-dev-files-111122223333/exports/*"] }]
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.files.policy).Statement) == 4
    error_message = "a write on a specific bucket prefix ARN is allowed"
  }
}

run "lifecycle_rules_with_prefix_filters" {
  command = plan

  variables {
    files_lifecycle_rules = [
      { id = "expire-tmp", prefix = "tmp/", expiration_days = 7 },
      { id = "expire-exports", prefix = "exports/", expiration_days = 90, noncurrent_expiration_days = 14 },
    ]
  }

  assert {
    condition = (
      length(aws_s3_bucket_lifecycle_configuration.files.rule) == 3 &&
      contains([for r in aws_s3_bucket_lifecycle_configuration.files.rule : r.id], "expire-old-versions") &&
      contains([for r in aws_s3_bucket_lifecycle_configuration.files.rule : r.filter[0].prefix], "tmp/") &&
      contains([for r in aws_s3_bucket_lifecycle_configuration.files.rule : r.filter[0].prefix], "exports/")
    )
    error_message = "the two rules are added beside the built-in one, each with its prefix filter"
  }
}

run "refuses_duplicate_rule_id" {
  command = plan
  variables {
    files_lifecycle_rules = [
      { id = "a", prefix = "x/", expiration_days = 1 },
      { id = "a", prefix = "y/", expiration_days = 1 },
    ]
  }
  expect_failures = [var.files_lifecycle_rules]
}

run "refuses_zero_days" {
  command = plan
  variables {
    files_lifecycle_rules = [{ id = "a", prefix = "x/", expiration_days = 0 }]
  }
  expect_failures = [var.files_lifecycle_rules]
}

run "system_log_level_is_set" {
  command = plan
  variables {
    system_log_level = "INFO"
  }

  assert {
    condition     = aws_lambda_function.app.logging_config[0].system_log_level == "INFO"
    error_message = "system_log_level reaches the function"
  }
}

run "refuses_unknown_log_level" {
  command = plan
  variables {
    system_log_level = "TRACE"
  }
  expect_failures = [var.system_log_level]
}
