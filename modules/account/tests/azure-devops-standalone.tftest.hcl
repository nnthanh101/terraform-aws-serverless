# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests with a mocked AWS provider: no account or credentials. A standalone account (outside AWS Organizations,
# security baseline on) that trusts Azure DevOps service connections instead of GitHub. The member-account mode is in azure-devops.tftest.hcl.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "ap-southeast-2"
    }
  }

  mock_data "aws_vpcs" {
    defaults = { ids = [] }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::123456789012:oidc-provider/created-by-this-plan" }
  }

  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:ap-southeast-2:123456789012:security-baseline-shared-alerts" }
  }
}

variables {
  account_id         = "123456789012"
  region             = "ap-southeast-2"
  default_branch     = "develop"
  budget_limit_usd   = 50
  notification_email = "owner@example.com"

  account_mode              = "single"
  environments              = ["dev", "production"]
  production_environments   = ["production"]
  security_baseline         = true
  change_id                 = "0073"
  create_state_kms_key      = false
  require_account_workspace = false
}

run "azure_devops_passes_through_to_bootstrap" {
  command = plan

  variables {
    ci_platform                = "azure-devops"
    ado_organization_id        = "11111111-1111-1111-1111-111111111111"
    ado_organization_name      = "acme"
    existing_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  assert {
    condition     = output.oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111" && join(",", sort(keys(output.apply_role_arns))) == "dev,production"
    error_message = "An account with ci_platform = azure-devops must trust the Azure DevOps provider and keep one apply role per environment."
  }
}

run "azure_devops_refuses_the_github_provider_arn" {
  command = plan

  variables {
    ci_platform                = "azure-devops"
    ado_organization_id        = "11111111-1111-1111-1111-111111111111"
    ado_organization_name      = "acme"
    existing_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  expect_failures = [var.existing_oidc_provider_arn]
}
