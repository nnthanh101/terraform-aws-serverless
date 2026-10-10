# Plan-only test of the consumer example with a mocked provider: no AWS account or credentials.
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
      api_endpoint  = "https://a1b2c3d4e5.execute-api.ap-southeast-2.amazonaws.com"
      execution_arn = "arn:aws:execute-api:ap-southeast-2:123456789012:a1b2c3d4e5"
    }
  }

  mock_resource "aws_lambda_alias" {
    defaults = {
      arn        = "arn:aws:lambda:ap-southeast-2:123456789012:function:shop-dev-api:live"
      invoke_arn = "arn:aws:apigateway:ap-southeast-2:lambda:path/2015-03-31/functions/arn:aws:lambda:ap-southeast-2:123456789012:function:shop-dev-api:live/invocations"
    }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:ap-southeast-2:123456789012:log-group:/aws/apigateway/shop-dev-api"
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
  target          = module.app.aws_s3_bucket.files
  override_during = plan
  values = {
    arn = "arn:aws:s3:::shop-dev-files-123456789012"
  }
}

override_resource {
  target          = module.app.aws_kms_key.files
  override_during = plan
  values = {
    arn    = "arn:aws:kms:ap-southeast-2:123456789012:key/11111111-1111-1111-1111-111111111111"
    key_id = "11111111-1111-1111-1111-111111111111"
  }
}

override_resource {
  target          = module.app.aws_secretsmanager_secret.secret_key
  override_during = plan
  values = {
    arn = "arn:aws:secretsmanager:ap-southeast-2:123456789012:secret:shop-dev-secret-key-AbCdEf"
  }
}

run "the_example_plans" {
  command = plan

  assert {
    condition     = output.function_name == "shop-dev-api" && output.site_url == "https://d111111abcdef8.cloudfront.net"
    error_message = "the example names its function <service>-<environment>-api and reports the site address"
  }
}
