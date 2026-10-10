# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# A web app on Lambda behind an HTTP API, its files in a versioned bucket (s3.tf), its signing key in a Secrets
# Manager secret or a Parameter Store parameter, alarms to a topic (alarms.tf), and the front-end on a
# distribution that also routes /api/* to the API (cdn.tf), so browser and API share one origin.

locals {
  name_prefix = "${var.service}-${var.environment}"
  role_path   = "/${var.workload_role_path}/${var.environment}/"
  jwt         = var.jwt_issuer != null

  # Environment of the function: the app's own variables (environment_variables), then these, which win.
  app_environment = {
    SERVICE     = var.service
    ENVIRONMENT = var.environment
    S3DB_BUCKET = aws_s3_bucket.files.bucket
    # One origin for browser and API (cdn.tf routes /api/*); never a wildcard.
    CORS_ORIGIN = "https://${aws_cloudfront_distribution.site.domain_name}"
  }

  # Where the signing key lives (variable secret_store). Exactly one of the two names reaches the function.
  secrets_manager = var.secret_store == "secrets-manager"
  # The parameter the root that applies the SecureString creates; the name is the contract between the two roots.
  secret_parameter_name = "/${var.service}/${var.environment}/secret-key"
  # Built from the name, never read: a data source would decrypt the value in every plan, which the plan roles deny.
  secret_parameter_arn = "arn:${data.aws_partition.files.partition}:ssm:${var.region}:${var.account_id}:parameter${local.secret_parameter_name}"

  secret_environment = local.secrets_manager ? {
    SECRET_KEY_SECRET = aws_secretsmanager_secret.secret_key[0].name
    } : {
    SECRET_KEY_PARAMETER = local.secret_parameter_name
  }

  # What cdn.tf and alarms.tf read about the API.
  overlay = {
    api_domain  = replace(aws_apigatewayv2_api.http.api_endpoint, "https://", "")
    api_path    = ""
    http_api_id = aws_apigatewayv2_api.http.id
    api_stage   = aws_apigatewayv2_stage.default.name
  }

  # A prebuilt zip is used as it is; otherwise the source folder is zipped.
  package_path = var.package_zip_path != null ? var.package_zip_path : data.archive_file.app[0].output_path
  package_hash = var.package_zip_path != null ? filebase64sha256(var.package_zip_path) : data.archive_file.app[0].output_base64sha256
}

# ------------------------------------------------------------------ function

data "archive_file" "app" {
  count            = var.package_zip_path == null ? 1 : 0
  type             = "zip"
  source_dir       = var.source_dir
  output_path      = "${coalesce(var.build_dir, "${path.root}/.build")}/${local.name_prefix}-api.zip"
  output_file_mode = "0644"
  excludes         = ["tests/**", "test/**", "**/__pycache__/**", "**/*.pyc"]
}

resource "aws_iam_role" "app" {
  name                 = "${local.name_prefix}-api"
  path                 = local.role_path
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "app" {
  # checkov:skip=CKV_AWS_158:0001 CloudWatch Logs encrypts at rest by default; a customer managed key per group adds cost and no reader control
  # checkov:skip=CKV_AWS_338:0001 retention is log_retention_days, set by the root with the budget approver
  name              = "/aws/lambda/${local.name_prefix}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role_policy" "logs" {
  name = "logs"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.app.arn}:*"
    }]
  })
}

resource "aws_lambda_function" "app" {
  # checkov:skip=CKV_AWS_50:0001 traces come from ADOT with Application Signals when the service adds them (lambda.md)
  # checkov:skip=CKV_AWS_116:0001 callers are synchronous and receive the error; a dead-letter queue applies only to asynchronous calls
  # checkov:skip=CKV_AWS_117:0001 the function calls only public AWS endpoints, so a VPC would add NAT cost and nothing to reach
  # checkov:skip=CKV_AWS_173:0001 the environment holds names only; secrets are read at run time, never stored here
  # checkov:skip=CKV_AWS_272:0001 only CI deploys code, from the reviewed and merged commit
  function_name    = "${local.name_prefix}-api"
  role             = aws_iam_role.app.arn
  runtime          = var.runtime
  handler          = var.handler
  architectures    = [var.architecture]
  memory_size      = var.memory_mb
  timeout          = var.timeout_seconds
  filename         = local.package_path
  source_code_hash = local.package_hash
  publish          = true
  # A few environments, not one: the page loads with parallel requests, and a second synchronous call
  # beyond the reserve is refused with 429, not queued. Correctness does not rest on this number: a
  # stale environment's write is refused by the conditional put (the app's s3db). Small,
  # so one function cannot take the account's concurrency.
  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = merge(var.environment_variables, local.app_environment, local.secret_environment)
  }

  logging_config {
    log_format            = "JSON"
    log_group             = aws_cloudwatch_log_group.app.name
    application_log_level = "INFO"
    system_log_level      = "WARN"
  }

  # The key's value is written before the function exists, so no start-up finds the secret empty
  # (parameter-store: the root that applies the SecureString is applied first, so the parameter exists before this root).
  depends_on = [aws_iam_role_policy.logs, aws_secretsmanager_secret_version.secret_key]
}

# Callers always reach the published version behind 'live'; a release moves the alias.
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.app.function_name
  function_version = aws_lambda_function.app.version
}

# ------------------------------------------------------------------ HTTP API

resource "aws_apigatewayv2_api" "http" {
  name          = "${local.name_prefix}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "app" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.live.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_authorizer" "jwt" {
  count            = local.jwt ? 1 : 0
  api_id           = aws_apigatewayv2_api.http.id
  name             = "${local.name_prefix}-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = var.jwt_issuer
    audience = var.jwt_audience
  }
}

resource "aws_apigatewayv2_route" "default" {
  api_id             = aws_apigatewayv2_api.http.id
  route_key          = "$default"
  target             = "integrations/${aws_apigatewayv2_integration.app.id}"
  authorization_type = local.jwt ? "JWT" : "NONE"
  authorizer_id      = local.jwt ? aws_apigatewayv2_authorizer.jwt[0].id : null
}

resource "aws_cloudwatch_log_group" "access" {
  # checkov:skip=CKV_AWS_158:0001 CloudWatch Logs encrypts at rest by default; a customer managed key per group adds cost and no reader control
  # checkov:skip=CKV_AWS_338:0001 retention is log_retention_days, set by the root with the budget approver
  name              = "/aws/apigateway/${local.name_prefix}-api"
  retention_in_days = var.log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      requestTime      = "$context.requestTime"
      sourceIp         = "$context.identity.sourceIp"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      protocol         = "$context.protocol"
      responseLength   = "$context.responseLength"
      responseLatency  = "$context.responseLatency"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowHttpApiInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.app.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

# ------------------------------------------------------------------ signing key

# The token signing key is generated once and written to a Secrets Manager secret through a
# write-only argument, so it is never in state, source or the function's environment. The function
# reads it at start-up through SECRET_KEY_SECRET. Rotate it by raising secret_string_wo_version.
# With secret_store = "parameter-store" none of this is created: the key is the SecureString that the
# owner applies in the root that applies the SecureString, and the function is only granted ssm:GetParameter on its name (SECRET_KEY_PARAMETER).
# A secret, not a SecureString parameter: the provider decrypts a SecureString on every refresh,
# which the plan roles' decrypt deny refuses, while a write-only secret version is refreshed through
# ListSecretVersionIds alone, which returns no value and which the plan roles may call.
ephemeral "random_password" "secret_key" {
  count   = local.secrets_manager ? 1 : 0
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "secret_key" {
  count = local.secrets_manager ? 1 : 0
  # checkov:skip=CKV_AWS_149:0003 the account's default Secrets Manager key needs no grant; a customer managed key adds cost and no reader control
  # checkov:skip=CKV2_AWS_57:0003 rotation is raising secret_string_wo_version in a release; the function reads the key once at start-up, so a scheduled rotation would leave warm environments on the old key
  name        = "${local.name_prefix}-secret-key"
  description = "Token signing key of ${local.name_prefix}-api, read once at start-up"
  # dev deletes at once, so a destroy and a new apply can reuse the name; every other environment,
  # whatever production is called, keeps a deleted key recoverable for 30 days.
  recovery_window_in_days = var.environment == "dev" ? 0 : 30
}

resource "aws_secretsmanager_secret_version" "secret_key" {
  count                    = local.secrets_manager ? 1 : 0
  secret_id                = aws_secretsmanager_secret.secret_key[0].id
  secret_string_wo         = ephemeral.random_password.secret_key[0].result
  secret_string_wo_version = 1
}

resource "aws_iam_role_policy" "secret_key" {
  name = "secret-key"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [local.secrets_manager ? {
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.secret_key[0].arn
      } : {
      Effect   = "Allow"
      Action   = "ssm:GetParameter"
      Resource = local.secret_parameter_arn
    }]
  })
}
