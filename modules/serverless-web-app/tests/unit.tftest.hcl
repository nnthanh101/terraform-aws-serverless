# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests of the function and the HTTP API, with mocked providers. No AWS account or credentials are used.

mock_provider "aws" {
  override_during = plan

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
}

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

run "defaults" {
  command = plan

  assert {
    condition     = aws_lambda_function.app.architectures == tolist(["arm64"])
    error_message = "The function must default to arm64."
  }

  assert {
    condition     = contains(["python3.13", "python3.14", "nodejs24.x"], aws_lambda_function.app.runtime)
    error_message = "The runtime must be python3.13, python3.14 or nodejs24.x."
  }

  assert {
    condition     = aws_lambda_function.app.publish && aws_lambda_alias.live.name == "live"
    error_message = "The function must publish versions behind the 'live' alias."
  }

  assert {
    condition     = aws_iam_role.app.path == "/workload/dev/" && aws_iam_role.app.permissions_boundary == var.permissions_boundary_arn
    error_message = "The role must sit under /workload/<env>/ and carry the workload boundary, or the apply role cannot create it."
  }

  assert {
    condition = alltrue([for n in [
      aws_lambda_function.app.function_name, aws_iam_role.app.name, aws_apigatewayv2_api.http.name,
    ] : startswith(n, "orders-dev-")])
    error_message = "Resource names must follow <service>-<environment>-<purpose>."
  }
}

run "lambda_proxy_payload_2" {
  command = plan

  assert {
    condition = (
      aws_apigatewayv2_integration.app.integration_type == "AWS_PROXY" &&
      aws_apigatewayv2_integration.app.payload_format_version == "2.0" &&
      aws_apigatewayv2_integration.app.integration_uri == aws_lambda_alias.live.invoke_arn
    )
    error_message = "The integration must be a Lambda proxy with payload 2.0 to the 'live' alias."
  }

  assert {
    condition = (
      aws_lambda_permission.api.principal == "apigateway.amazonaws.com" &&
      aws_lambda_permission.api.qualifier == "live" &&
      aws_lambda_permission.api.source_arn == "arn:aws:execute-api:aa-example-1:111122223333:a1b2c3d4e5/*/*"
    )
    error_message = "Only this API may invoke the 'live' alias."
  }
}

run "stage_logs_and_throttling" {
  command = plan

  assert {
    condition     = aws_apigatewayv2_stage.default.name == "$default" && aws_apigatewayv2_stage.default.auto_deploy
    error_message = "The $default stage must deploy automatically."
  }

  assert {
    condition     = aws_apigatewayv2_stage.default.access_log_settings[0].destination_arn == aws_cloudwatch_log_group.access.arn
    error_message = "The stage must write access logs to its log group."
  }

  assert {
    condition     = jsondecode(aws_apigatewayv2_stage.default.access_log_settings[0].format).status == "$context.status"
    error_message = "Access logs must be JSON and record the status."
  }

  assert {
    condition = (
      aws_apigatewayv2_stage.default.default_route_settings[0].throttling_rate_limit == 50 &&
      aws_apigatewayv2_stage.default.default_route_settings[0].throttling_burst_limit == 100
    )
    error_message = "The stage must throttle the API."
  }
}

run "open_without_jwt" {
  command = plan

  assert {
    condition     = aws_apigatewayv2_route.default.authorization_type == "NONE" && length(aws_apigatewayv2_authorizer.jwt) == 0
    error_message = "Without jwt_issuer the route has no authorizer."
  }
}

run "jwt_authorizer" {
  command = plan

  variables {
    jwt_issuer   = "https://issuer.example.com"
    jwt_audience = ["orders-web"]
  }

  assert {
    condition = (
      aws_apigatewayv2_route.default.authorization_type == "JWT" &&
      aws_apigatewayv2_authorizer.jwt[0].jwt_configuration[0].issuer == "https://issuer.example.com"
    )
    error_message = "With jwt_issuer the route must require a JWT from that issuer."
  }
}

run "jwt_needs_audience" {
  command = plan

  variables {
    jwt_issuer = "https://issuer.example.com"
  }

  expect_failures = [var.jwt_audience]
}

run "architecture_rejects_arm" {
  command = plan

  variables {
    architecture = "arm"
  }

  expect_failures = [var.architecture]
}

run "runtime_rejects_deprecated" {
  command = plan

  variables {
    runtime = "nodejs20.x"
  }

  expect_failures = [var.runtime]
}

run "boundary_of_another_environment_rejected" {
  command = plan

  variables {
    environment = "production"
  }

  expect_failures = [var.permissions_boundary_arn]
}

run "package_zip_replaces_source_dir" {
  command = plan

  variables {
    source_dir       = null
    package_zip_path = "versions.tf"
  }

  assert {
    condition     = length(data.archive_file.app) == 0 && aws_lambda_function.app.filename == "versions.tf"
    error_message = "A prebuilt zip path is used as it is and nothing is archived."
  }
}

run "source_dir_or_zip_not_both_and_not_neither" {
  command = plan

  variables {
    source_dir       = null
    package_zip_path = null
  }

  expect_failures = [var.source_dir]
}

run "x86_64_needs_an_exception" {
  command = plan

  variables {
    architecture = "x86_64"
  }

  expect_failures = [var.architecture]
}

run "x86_64_with_an_exception_plans" {
  command = plan

  variables {
    architecture           = "x86_64"
    architecture_exception = "dependency without an arm64 build"
  }

  assert {
    condition     = aws_lambda_function.app.architectures == tolist(["x86_64"])
    error_message = "x86_64 is accepted once an exception is given"
  }
}

run "build_dir_sets_where_the_zip_is_written" {
  command = plan

  variables {
    build_dir = "out"
  }

  assert {
    condition     = data.archive_file.app[0].output_path == "out/orders-dev-api.zip"
    error_message = "the zip is written under the caller's build_dir"
  }
}

run "image_mode_runs_a_pinned_container_image" {
  command = plan

  variables {
    source_dir = null
    image_uri  = "111122223333.dkr.ecr.aa-example-1.amazonaws.com/orders@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }

  assert {
    condition     = aws_lambda_function.app.package_type == "Image" && aws_lambda_function.app.image_uri == var.image_uri
    error_message = "image_uri must make the function a container image at that uri."
  }

  assert {
    condition     = aws_lambda_function.app.handler == null && aws_lambda_function.app.runtime == null && aws_lambda_function.app.filename == null
    error_message = "An image function has no handler, runtime or filename."
  }

  assert {
    condition     = length(data.archive_file.app) == 0
    error_message = "Image mode must not build an archive."
  }

  assert {
    condition     = aws_lambda_function.app.architectures == tolist(["arm64"])
    error_message = "Image mode keeps the architecture."
  }
}

run "image_tag_only_is_rejected" {
  command = plan

  variables {
    source_dir = null
    image_uri  = "111122223333.dkr.ecr.aa-example-1.amazonaws.com/orders:latest"
  }

  expect_failures = [var.image_uri]
}

run "environment_secret_sets_secret_key_without_a_store" {
  command = plan

  variables {
    secret_store = "environment"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.secret_key) == 0 && length(aws_secretsmanager_secret_version.secret_key) == 0
    error_message = "environment mode must create no Secrets Manager secret."
  }

  assert {
    condition     = length(random_password.secret_key) == 1 && length(aws_iam_role_policy.secret_key) == 0
    error_message = "environment mode generates the key and adds no secret-read policy."
  }

  assert {
    condition     = contains(keys(nonsensitive(aws_lambda_function.app.environment[0].variables)), "SECRET_KEY") && !contains(keys(nonsensitive(aws_lambda_function.app.environment[0].variables)), "SECRET_KEY_SECRET") && !contains(keys(nonsensitive(aws_lambda_function.app.environment[0].variables)), "SECRET_KEY_PARAMETER")
    error_message = "SECRET_KEY, and neither store variable, must be in the environment."
  }
}

run "no_reservation_with_null_concurrency" {
  command = plan

  variables {
    reserved_concurrency = null
  }

  assert {
    condition     = aws_lambda_function.app.reserved_concurrent_executions == null
    error_message = "A null reserved_concurrency must reserve nothing."
  }
}

run "reserved_concurrency_out_of_range_is_rejected" {
  command = plan

  variables {
    reserved_concurrency = 101
  }

  expect_failures = [var.reserved_concurrency]
}

run "default_caller_is_unchanged" {
  command = plan

  assert {
    condition     = aws_lambda_function.app.package_type == "Zip" && aws_lambda_function.app.handler == "handler.handler" && aws_lambda_function.app.runtime == "python3.13" && length(data.archive_file.app) == 1
    error_message = "Without image_uri the function is the zip function."
  }

  assert {
    condition     = aws_lambda_function.app.reserved_concurrent_executions == 4 && length(aws_secretsmanager_secret.secret_key) == 1 && length(random_password.secret_key) == 0 && length(aws_iam_role_policy.secret_key) == 1
    error_message = "The defaults keep concurrency 4, the Secrets Manager secret and its read policy."
  }
}
