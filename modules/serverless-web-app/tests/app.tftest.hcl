# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests of the signing key, the single writer, the app's environment and the site digest, with mocked providers.

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
  environment_variables = {
    S3DB_KEY      = "navigator.db"
    DATABASE_PATH = "/tmp/navigator.db"
  }
}

# What this module adds to the http-api example: one writer, a signing key that never reaches state,
# and the two things the site publish reads (site.tf). Default store: Secrets Manager.
run "signing_key_and_single_writer" {
  command = plan

  assert {
    condition     = aws_lambda_function.app.reserved_concurrent_executions >= 2 && aws_lambda_function.app.reserved_concurrent_executions <= 4
    error_message = "reserved concurrency stays between 2 (parallel page loads) and 4 (one function cannot take the account's pool); a stale write is refused by the conditional put, not by concurrency"
  }

  assert {
    condition     = aws_secretsmanager_secret.secret_key[0].name == "orders-dev-secret-key" && aws_secretsmanager_secret.secret_key[0].recovery_window_in_days == 0
    error_message = "the signing key must be a secret named after the service and environment; dev deletes it at once so the name can be reused"
  }

  assert {
    condition = (
      aws_secretsmanager_secret_version.secret_key[0].secret_id == aws_secretsmanager_secret.secret_key[0].id &&
      aws_secretsmanager_secret_version.secret_key[0].secret_string_wo_version == 1 &&
      aws_secretsmanager_secret_version.secret_key[0].secret_string == null &&
      aws_secretsmanager_secret_version.secret_key[0].secret_binary == null
    )
    error_message = "the key is written to the secret through secret_string_wo only (version 1): no secret_string or secret_binary in the plan, so it never reaches state and a refresh never reads its value"
  }

  assert {
    condition     = !contains(keys(aws_lambda_function.app.environment[0].variables), "SECRET_KEY") && !contains(keys(aws_lambda_function.app.environment[0].variables), "SECRET_KEY_PARAMETER")
    error_message = "the function receives the secret's name, never the key itself, and no parameter name is left behind in secrets-manager mode"
  }

  assert {
    condition     = aws_lambda_function.app.environment[0].variables["SECRET_KEY_SECRET"] == aws_secretsmanager_secret.secret_key[0].name
    error_message = "SECRET_KEY_SECRET must name the secret the function reads at start-up"
  }

  assert {
    condition = (
      aws_lambda_function.app.environment[0].variables["S3DB_BUCKET"] == aws_s3_bucket.files.bucket &&
      aws_lambda_function.app.environment[0].variables["S3DB_KEY"] == "navigator.db" &&
      !contains(keys(aws_lambda_function.app.environment[0].variables), "SQLITE_S3_BUCKET")
    )
    error_message = "the app's own s3db layer is told the bucket and key of its database object; no SQLITE_S3_* key is left behind"
  }

  assert {
    condition = (
      aws_lambda_function.app.environment[0].variables["CORS_ORIGIN"] != "*" &&
      aws_lambda_function.app.environment[0].variables["CORS_ORIGIN"] == "https://d111111abcdef8.cloudfront.net"
    )
    error_message = "CORS_ORIGIN must be the site's https origin, never a wildcard"
  }

  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.files.policy).Statement[0].Action, "s3:ListBucketVersions") && contains(jsondecode(aws_iam_role_policy.files.policy).Statement[0].Action, "s3:ListBucket")
    error_message = "ListFiles must include s3:ListBucketVersions: s3db recovers an ambiguous put by listing object versions"
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.secret_key.policy).Statement) == 1 &&
      jsondecode(aws_iam_role_policy.secret_key.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.secret_key.policy).Statement[0].Action == "secretsmanager:GetSecretValue" &&
      jsondecode(aws_iam_role_policy.secret_key.policy).Statement[0].Resource == "arn:aws:secretsmanager:aa-example-1:111122223333:secret:orders-dev-secret-key-AbCdEf"
    )
    error_message = "the secret-key grant is exactly one statement: secretsmanager:GetSecretValue on this one secret's ARN, no wildcard"
  }

  assert {
    condition     = output.site_distribution_id == aws_cloudfront_distribution.site.id
    error_message = "site_distribution_id must name the CloudFront distribution the pipeline invalidates after it uploads the site"
  }

  assert {
    condition     = contains(local.site_files, "index.html") && !contains(local.site_files, "_nocache_server.py") && !contains(local.site_files, "Dockerfile") && !contains(local.site_files, "nginx.conf") && !contains(local.site_files, ".dockerignore") && terraform_data.site_content.input != sha256("")
    error_message = "site_content must digest the published front-end files: index.html in, the local preview server out, never an empty set"
  }

}

# The start-up tenant's store: the SecureString is made by infra/app-key, so this root creates no secret,
# reads nothing (a data source would decrypt in every plan, which the plan roles deny) and grants read on the name.
run "parameter_store_key" {
  command = plan

  variables {
    secret_store = "parameter-store"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.secret_key) == 0 && length(aws_secretsmanager_secret_version.secret_key) == 0
    error_message = "parameter-store creates no Secrets Manager secret or version"
  }

  assert {
    condition = (
      aws_lambda_function.app.environment[0].variables["SECRET_KEY_PARAMETER"] == "/orders/dev/secret-key" &&
      !contains(keys(aws_lambda_function.app.environment[0].variables), "SECRET_KEY_SECRET") &&
      !contains(keys(aws_lambda_function.app.environment[0].variables), "SECRET_KEY")
    )
    error_message = "the function receives the parameter's name as SECRET_KEY_PARAMETER, never SECRET_KEY_SECRET or the key itself"
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.secret_key.policy).Statement) == 1 &&
      jsondecode(aws_iam_role_policy.secret_key.policy).Statement[0].Effect == "Allow" &&
      jsondecode(aws_iam_role_policy.secret_key.policy).Statement[0].Action == "ssm:GetParameter" &&
      jsondecode(aws_iam_role_policy.secret_key.policy).Statement[0].Resource == "arn:aws:ssm:aa-example-1:111122223333:parameter/orders/dev/secret-key"
    )
    error_message = "the key grant is exactly one statement: ssm:GetParameter on the one parameter's ARN built from its name, no wildcard and no kms action"
  }
}

run "secret_store_is_validated" {
  command = plan

  variables {
    secret_store = "vault"
  }

  expect_failures = [var.secret_store]
}
