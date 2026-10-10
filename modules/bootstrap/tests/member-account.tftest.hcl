# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Tier 1: the three member-account kinds in examples/member-account, planned against a mocked AWS provider. Each kind
# is planned once through the example, so the example stays a working caller, and once through the module itself, so
# the guarantee behind it can be asserted on the planned roles and policies. Repository names and IDs are fixtures.
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
  account_id              = "444455556666"
  region                  = "ap-southeast-2"
  github_repositories     = ["acme/platform"]
  github_repository_ids   = ["123456789"]
  github_subject_prefixes = ["repo:acme@987654/platform@123456789"]
  github_owner_id         = "987654"
  default_branch          = "main"
  budget_limit_usd        = 100
  notification_email      = "finance@example.com"
  change_id               = "0021"
  tags                    = { service = "platform", change = "0021" }
}

# ---------------------------------------------------------------- Workload: dev and production in one account

run "workload_example_plans" {
  command = plan

  module {
    source = "./examples/member-account"
  }
  variables {
    account_mode            = "single"
    environments            = ["dev", "production"]
    production_environments = ["production"]
    apply_workflow_refs     = { production = ["acme/platform/.github/workflows/release.yml@refs/heads/main"] }
  }

  assert {
    condition     = join(",", sort(keys(output.apply_role_arns))) == "dev,production" && length(output.plan_role_arns) == 2 && length(output.workload_boundary_policy_arns) == 2
    error_message = "the Workload account gets an apply role and a boundary per environment, and the two read-only plan roles"
  }
}

run "workload_dev_is_denied_production" {
  command = plan

  variables {
    account_mode            = "single"
    environments            = ["dev", "production"]
    production_environments = ["production"]
    apply_workflow_refs     = { production = ["acme/platform/.github/workflows/release.yml@refs/heads/main"] }
  }

  assert {
    condition     = keys(aws_iam_role_policy.apply_production_deny) == ["dev"]
    error_message = "in one account, dev's apply role carries the production deny and production's does not"
  }
  assert {
    condition = (
      jsondecode(aws_iam_role.apply["production"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:acme@987654/platform@123456789:environment:production"] &&
      jsondecode(aws_iam_role.apply["production"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:job_workflow_ref"] == ["acme/platform/.github/workflows/release.yml@refs/heads/main"] &&
      !strcontains(aws_iam_role.apply["dev"].assume_role_policy, "job_workflow_ref")
    )
    error_message = "production trusts the repository's immutable subject for its Environment and only the release workflow"
  }
}

# Each refusal names one rule: no environment is called production here, so only the single-account rule applies.
run "single_account_without_a_production_environment_is_refused" {
  command = plan

  variables {
    account_mode            = "single"
    environments            = ["dev", "staging"]
    production_environments = []
  }
  expect_failures = [var.production_environments]
}

# One account per environment, so only the rule that an environment named production is listed as production applies.
run "an_environment_named_production_must_be_listed_as_production" {
  command = plan

  variables {
    account_mode            = "landing-zone"
    environments            = ["production"]
    production_environments = []
  }
  expect_failures = [var.production_environments]
}

# ---------------------------------------------------------------- Sandbox: one environment, no production role

run "sandbox_example_plans" {
  command = plan

  module {
    source = "./examples/member-account"
  }
  variables {
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }

  assert {
    condition     = keys(output.apply_role_arns) == ["sandbox"] && length(output.plan_role_arns) == 2
    error_message = "the Sandbox gets one apply role, for its own environment, and no production role"
  }
}

run "sandbox_has_no_production_role" {
  command = plan

  variables {
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }

  assert {
    condition     = keys(aws_iam_role.apply) == ["sandbox"] && length(aws_iam_role_policy.apply_production_deny) == 0
    error_message = "the Sandbox's only apply role is its own environment's, and it holds no production role"
  }
  assert {
    condition     = jsondecode(aws_iam_role.apply["sandbox"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:acme@987654/platform@123456789:environment:sandbox"]
    error_message = "the Sandbox's apply role trusts only its own GitHub Environment"
  }
}

# ---------------------------------------------------------------- Card data: production only, one release workflow

run "card_data_example_plans" {
  command = plan

  module {
    source = "./examples/member-account"
  }
  variables {
    github_repositories     = ["acme/payments"]
    github_repository_ids   = ["123456790"]
    github_subject_prefixes = ["repo:acme@987654/payments@123456790"]
    account_mode            = "landing-zone"
    environments            = ["production"]
    production_environments = ["production"]
    apply_workflow_refs     = { production = ["acme/payments/.github/workflows/release.yml@refs/heads/main"] }
  }

  assert {
    condition     = keys(output.apply_role_arns) == ["production"]
    error_message = "the card-data account holds production only, so no other environment shares its roles"
  }
}

run "card_data_trust_is_bound_to_the_payment_repository" {
  command = plan

  variables {
    github_repositories     = ["acme/payments"]
    github_repository_ids   = ["123456790"]
    github_subject_prefixes = ["repo:acme@987654/payments@123456790"]
    account_mode            = "landing-zone"
    environments            = ["production"]
    production_environments = ["production"]
    apply_workflow_refs     = { production = ["acme/payments/.github/workflows/release.yml@refs/heads/main"] }
  }

  assert {
    condition = alltrue([
      for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) : (
        jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:repository_id"] == ["123456790"] &&
        jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:repository_owner_id"] == "987654"
      )
    ])
    error_message = "every role in the card-data account requires the payment repository's ID and its owner's ID"
  }
  assert {
    condition     = length(aws_iam_role_policy.apply_production_deny) == 0
    error_message = "one environment needs no production deny"
  }
}

run "card_data_trust_for_another_repository_is_refused" {
  command = plan

  variables {
    github_repositories     = ["acme/payments"]
    github_subject_prefixes = ["repo:acme/platform"]
    account_mode            = "landing-zone"
    environments            = ["production"]
    production_environments = ["production"]
  }
  expect_failures = [var.github_subject_prefixes]
}
