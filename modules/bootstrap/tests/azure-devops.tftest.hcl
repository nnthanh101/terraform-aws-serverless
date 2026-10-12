# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Derived from the terraform-aws plugin's bootstrap template. See NOTICE.txt.
# Tier 1: plan-only tests with a mocked AWS provider: no credentials, no real resources.
# Azure DevOps sign-in (ci_platform = azure-devops) and proof that the default github plan is unchanged.
mock_provider "aws" {
  override_data {
    target = data.aws_partition.current
    values = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      region = "ap-southeast-2"
    }
  }

  override_resource {
    target          = aws_kms_key.state
    override_during = plan
    values = {
      arn    = "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  account_id         = "123456789012"
  region             = "ap-southeast-2"
  default_branch     = "develop"
  state_bucket_name  = "acme-shared-tfstate-123456789012"
  budget_limit_usd   = 250
  notification_email = "finance@example.com"
  change_id          = "0001"
}

# ------------------------------------------------------------------ default github: trust unchanged

run "github_default_trust_is_unchanged" {
  command = plan

  variables {
    github_repositories = ["acme/platform"]
  }

  assert {
    condition = (
      aws_iam_role.plan["pr"].assume_role_policy == jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid       = "GitHubActionsOidc"
          Effect    = "Allow"
          Action    = "sts:AssumeRoleWithWebIdentity"
          Principal = { Federated = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
          Condition = { StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = ["repo:acme/platform:pull_request"]
          } }
        }]
      })
      && aws_iam_role.apply["production"].assume_role_policy == jsonencode({
        Version = "2012-10-17"
        Statement = [{
          Sid       = "GitHubActionsOidc"
          Effect    = "Allow"
          Action    = "sts:AssumeRoleWithWebIdentity"
          Principal = { Federated = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com" }
          Condition = { StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = ["repo:acme/platform:environment:production"]
          } }
        }]
      })
    )
    error_message = "The default (github) trust documents must read exactly as before ci_platform existed."
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1 && aws_iam_openid_connect_provider.github[0].url == "https://token.actions.githubusercontent.com" && aws_iam_openid_connect_provider.github[0].client_id_list == toset(["sts.amazonaws.com"])
    error_message = "The default provider must stay the GitHub one."
  }

  assert {
    condition     = aws_iam_role.apply["dev"].description == "Terraform apply for dev, only from the GitHub Environment dev"
    error_message = "The GitHub apply role description must not change."
  }
}

# ------------------------------------------------------------------ azure-devops

run "azure_devops_creates_its_provider_and_no_github_provider" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1 && aws_iam_openid_connect_provider.github[0].url == "https://vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111"
    error_message = "The provider must be the Azure DevOps issuer of the organization."
  }

  assert {
    condition     = aws_iam_openid_connect_provider.github[0].client_id_list == toset(["api://AzureADTokenExchange"])
    error_message = "The provider's client id must be api://AzureADTokenExchange."
  }

  assert {
    condition     = !strcontains(jsonencode(output.policy_documents), "token.actions.githubusercontent.com")
    error_message = "No trust may name the GitHub issuer under azure-devops."
  }

  assert {
    condition     = alltrue([for r in ["pr", "default"] : contains(keys(aws_iam_role.plan), r)]) && contains(keys(aws_iam_role.apply), "dev") && contains(keys(aws_iam_role.apply), "production")
    error_message = "The same plan and apply roles must exist as under github."
  }
}

run "azure_devops_trust_is_exact_string_equals" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
      { project = "platform", name = "aws-plan" },
      { project = "data", name = "aws-plan-data" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }, { project = "data", name = "aws-apply-prod-data" }]
    }
  }

  assert {
    condition = (
      jsonencode(jsondecode(aws_iam_role.plan["pr"].assume_role_policy).Statement[0].Condition) == jsonencode({
        StringEquals = {
          "vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111:aud" = "api://AzureADTokenExchange"
          "vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111:sub" = ["sc://acme/platform/aws-plan", "sc://acme/data/aws-plan-data"]
        }
      })
      && aws_iam_role.plan["default"].assume_role_policy == aws_iam_role.plan["pr"].assume_role_policy
    )
    error_message = "Both plan roles must trust exactly the plan subjects (duplicates removed) with StringEquals on aud and sub."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.apply["dev"].assume_role_policy).Statement[0].Condition.StringEquals["vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111:sub"] == ["sc://acme/platform/aws-apply-dev"]
      && jsondecode(aws_iam_role.apply["production"].assume_role_policy).Statement[0].Condition.StringEquals["vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111:sub"] == ["sc://acme/platform/aws-apply-prod", "sc://acme/data/aws-apply-prod-data"]
    )
    error_message = "Each apply role must trust only its own environment's subjects."
  }

  assert {
    condition = alltrue([
      for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) :
      !contains(keys(jsondecode(r.assume_role_policy).Statement[0].Condition), "StringLike") && keys(jsondecode(r.assume_role_policy).Statement[0].Condition) == ["StringEquals"]
    ])
    error_message = "No Azure DevOps trust may use StringLike."
  }

  assert {
    condition = length(setintersection(
      toset(jsondecode(aws_iam_role.plan["pr"].assume_role_policy).Statement[0].Condition.StringEquals["vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111:sub"]),
      toset(flatten([for e in ["dev", "production"] : jsondecode(aws_iam_role.apply[e].assume_role_policy).Statement[0].Condition.StringEquals["vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111:sub"]]))
    )) == 0
    error_message = "No subject may be trusted by both the plan roles and an apply role."
  }

  assert {
    condition = alltrue([
      for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) :
      !strcontains(r.assume_role_policy, "*") && !strcontains(r.assume_role_policy, "?")
    ])
    error_message = "No Azure DevOps trust may contain a wildcard character."
  }

  assert {
    condition     = length(aws_iam_policy.workload_boundary) == 2 && aws_s3_bucket.state.bucket == "acme-shared-tfstate-123456789012"
    error_message = "The state bucket and one boundary per environment are shared with github."
  }
}

run "azure_devops_reuses_an_existing_provider" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    create_oidc_provider  = false
    oidc_provider_arn     = "arn:aws:iam::123456789012:oidc-provider/vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && output.oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/vstoken.dev.azure.com/11111111-1111-1111-1111-111111111111"
    error_message = "A reused Azure DevOps provider must be trusted and no provider created."
  }
}

run "azure_devops_refuses_the_github_provider_arn" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    create_oidc_provider  = false
    oidc_provider_arn     = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  expect_failures = [var.oidc_provider_arn]
}

run "azure_devops_refuses_a_wildcard_plan_name" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-*" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  expect_failures = [var.ado_plan_service_connections]
}

run "azure_devops_refuses_a_wildcard_apply_name" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "plat?form", name = "aws-apply-prod" }]
    }
  }

  expect_failures = [var.ado_apply_service_connections]
}

run "azure_devops_refuses_a_wildcard_organization_name" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "ac$me"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  expect_failures = [var.ado_organization_name]
}

run "azure_devops_refuses_an_apply_key_outside_environments" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
      staging    = [{ project = "platform", name = "aws-apply-staging" }]
    }
  }

  expect_failures = [var.ado_apply_service_connections]
}

run "azure_devops_needs_an_apply_connection_for_every_environment" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev = [{ project = "platform", name = "aws-apply-dev" }]
    }
  }

  expect_failures = [var.ado_apply_service_connections]
}

run "azure_devops_needs_a_plan_connection" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  expect_failures = [var.ado_plan_service_connections]
}

run "azure_devops_needs_a_valid_organization_id" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "NOT-A-GUID"
    ado_organization_name = "acme"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  expect_failures = [var.ado_organization_id]
}

run "azure_devops_needs_no_github_inputs" {
  command = plan

  variables {
    ci_platform           = "azure-devops"
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  assert {
    condition     = length(aws_iam_role.plan) == 2
    error_message = "azure-devops must plan without github_repositories."
  }
}

# ------------------------------------------------------------------ azure-devops inputs under github

run "github_refuses_azure_devops_inputs" {
  command = plan

  variables {
    github_repositories   = ["acme/platform"]
    ado_organization_id   = "11111111-1111-1111-1111-111111111111"
    ado_organization_name = "acme"
    ado_plan_service_connections = [
      { project = "platform", name = "aws-plan" },
    ]
    ado_apply_service_connections = {
      dev = [{ project = "platform", name = "aws-apply-dev" }]
    }
  }

  expect_failures = [var.ado_organization_id, var.ado_organization_name, var.ado_plan_service_connections]
}

run "github_still_needs_repositories" {
  command = plan

  expect_failures = [var.github_repositories]
}

run "unknown_ci_platform_is_refused" {
  command = plan

  variables {
    ci_platform         = "gitlab"
    github_repositories = ["acme/platform"]
  }

  expect_failures = [var.ci_platform]
}

run "azure_devops_refuses_one_connection_for_plan_and_both_applies" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws" }]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws" }]
      production = [{ project = "platform", name = "aws" }]
    }
  }

  expect_failures = [var.ado_apply_service_connections]
}

run "azure_devops_refuses_one_connection_for_plan_and_apply" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws" }]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  expect_failures = [var.ado_apply_service_connections]
}

run "azure_devops_refuses_one_connection_for_two_environments" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws-plan" }]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws" }]
      production = [{ project = "platform", name = "aws" }]
    }
  }

  expect_failures = [var.ado_apply_service_connections]
}

run "azure_devops_refuses_a_case_only_difference" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws" }]
    ado_apply_service_connections = {
      dev        = [{ project = "Platform", name = "AWS" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
  }

  expect_failures = [var.ado_apply_service_connections]
}

run "azure_devops_refuses_another_organizations_provider" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws-plan" }]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
    create_oidc_provider = false
    oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/vstoken.dev.azure.com/22222222-2222-2222-2222-222222222222"
  }

  expect_failures = [var.oidc_provider_arn]
}

run "azure_devops_refuses_github_repositories" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws-plan" }]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
    github_repositories = ["acme/platform"]
  }

  expect_failures = [var.github_repositories]
}

run "azure_devops_refuses_github_repository_ids" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws-plan" }]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
    github_repository_ids = ["123"]
  }

  expect_failures = [var.github_repository_ids]
}

run "azure_devops_refuses_github_subject_prefixes" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws-plan" }]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
    github_subject_prefixes = ["repo:acme/platform"]
  }

  expect_failures = [var.github_subject_prefixes]
}

run "azure_devops_refuses_github_owner_id" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws-plan" }]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
    github_owner_id = "987"
  }

  expect_failures = [var.github_owner_id]
}

run "azure_devops_refuses_github_owner_ids" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws-plan" }]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
    github_owner_ids = ["987"]
  }

  expect_failures = [var.github_owner_ids]
}

run "azure_devops_refuses_apply_workflow_refs" {
  command = plan

  variables {
    ci_platform                  = "azure-devops"
    ado_organization_id          = "11111111-1111-1111-1111-111111111111"
    ado_organization_name        = "acme"
    ado_plan_service_connections = [{ project = "platform", name = "aws-plan" }]
    ado_apply_service_connections = {
      dev        = [{ project = "platform", name = "aws-apply-dev" }]
      production = [{ project = "platform", name = "aws-apply-prod" }]
    }
    apply_workflow_refs = { production = ["acme/platform/.github/workflows/release.yml@refs/heads/develop"] }
  }

  expect_failures = [var.apply_workflow_refs]
}

run "github_refuses_azure_devops_apply_connections" {
  command = plan

  variables {
    github_repositories = ["acme/platform"]
    ado_apply_service_connections = {
      dev = [{ project = "platform", name = "aws-apply-dev" }]
    }
  }

  expect_failures = [var.ado_apply_service_connections]
}
