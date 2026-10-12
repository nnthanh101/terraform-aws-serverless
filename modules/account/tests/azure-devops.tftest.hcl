# Plan-only tests with a mocked AWS provider: no credentials, no real resources. The bootstrap module's own runs live
# in modules/bootstrap/tests; these assert only what this module adds. Account 444455556666 is the member account and
# 111122223333 the management account. terraform test runs in the default workspace, so the workspace rule is off
# except where a run proves it.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "444455556666" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-southeast-2" }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-00000000000000001" }
  }
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"] }
  }
  mock_data "aws_subnet" {
    defaults = { availability_zone = "ap-southeast-2a" }
  }
  mock_data "aws_organizations_organization" {
    defaults = { master_account_id = "111122223333" }
  }
  mock_data "aws_internet_gateway" {
    defaults = { internet_gateway_id = "igw-00000000000000001" }
  }
  # The default VPC's gateway is imported; the mock plants the state the import reads.
  mock_resource "aws_internet_gateway" {
    defaults = {
      id       = "igw-00000000000000001"
      vpc_id   = "vpc-00000000000000001"
      arn      = "arn:aws:ec2:ap-southeast-2:444455556666:internet-gateway/igw-00000000000000001"
      owner_id = "444455556666"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:ap-southeast-2:444455556666:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::444455556666:oidc-provider/token.actions.githubusercontent.com" }
  }
}

variables {
  account_id         = "444455556666"
  region             = "ap-southeast-2"
  default_branch     = "develop"
  budget_limit_usd   = 100
  notification_email = "finance@example.com"
  change_id          = "0037"
  security_baseline  = false
  tags               = { service = "platform", change = "0037" }

  require_account_workspace = false
}

run "azure_devops_passes_through_to_bootstrap" {
  command = plan

  variables {
    account_mode            = "single"
    environments            = ["dev", "production"]
    production_environments = ["production"]
    ci_platform             = "azure-devops"
    ado_organization_id     = "11111111-1111-1111-1111-111111111111"
    ado_organization_name   = "acme"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  assert {
    condition     = strcontains(jsonencode(output.policy_documents.trust), "vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111:sub") && strcontains(jsonencode(output.policy_documents.trust), "sc://acme/platform/aws-apply-prod") && !strcontains(jsonencode(output.policy_documents.trust), "githubusercontent")
    error_message = "A member account with ci_platform = azure-devops must trust its service connections and no GitHub issuer."
  }
}

run "azure_devops_refuses_github_inputs" {
  command = plan

  variables {
    account_mode            = "single"
    environments            = ["dev", "production"]
    production_environments = ["production"]
    ci_platform             = "azure-devops"
    ado_organization_id     = "11111111-1111-1111-1111-111111111111"
    ado_organization_name   = "acme"
    github_repositories     = ["acme/platform"]
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  expect_failures = [var.github_repositories]
}
