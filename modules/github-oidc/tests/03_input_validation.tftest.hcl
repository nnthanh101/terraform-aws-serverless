# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Tier 1 snapshot test: input validation. Each run passes one input a real caller could get wrong
# (a wildcard in a repository name, a full URL for the org, a role name IAM rejects, a policy name that is not an ARN,
# a ref claim that is not a ref or environment) and expects the plan to stop at that variable.

mock_provider "aws" {}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:user/test"
    user_id    = "AIDAEXAMPLE"
  }
}

override_data {
  target = data.aws_iam_policy_document.plan_trust
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

override_data {
  target = data.aws_iam_policy_document.apply_trust
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
  }
}

override_resource {
  target          = aws_iam_openid_connect_provider.github[0]
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }
}

variables {
  github_org          = "example-org"
  github_repositories = ["example-repo"]
  apply_policy_arns   = ["arn:aws:iam::aws:policy/AmazonS3FullAccess"]
}

run "valid_inputs_plan" {
  command = plan

  variables {
    apply_allowed_refs = ["ref:refs/heads/main", "environment:production"]
  }

  assert {
    condition     = length(aws_iam_role.apply) == 1
    error_message = "valid inputs, including an environment claim, plan"
  }
}

run "org_must_be_a_name_not_a_url" {
  command = plan

  variables {
    github_org = "https://github.com/example-org"
  }

  expect_failures = [var.github_org]
}

run "repository_wildcard_is_refused" {
  command = plan

  variables {
    github_repositories = ["*"]
  }

  expect_failures = [var.github_repositories]
}

run "repository_with_org_prefix_is_refused" {
  command = plan

  variables {
    github_repositories = ["example-org/example-repo"]
  }

  expect_failures = [var.github_repositories]
}

run "repositories_must_not_be_empty" {
  command = plan

  variables {
    github_repositories = []
  }

  expect_failures = [var.github_repositories]
}

run "role_name_must_be_an_iam_name" {
  command = plan

  variables {
    plan_role_name = "has spaces"
  }

  expect_failures = [var.plan_role_name]
}

run "apply_role_name_too_long" {
  command = plan

  variables {
    apply_role_name = "a-role-name-that-runs-past-the-sixty-four-character-limit-of-iam-roles"
  }

  expect_failures = [var.apply_role_name]
}

run "plan_policy_must_be_an_arn" {
  command = plan

  variables {
    plan_policy_arns = ["ReadOnlyAccess"]
  }

  expect_failures = [var.plan_policy_arns]
}

run "apply_policy_must_be_an_arn" {
  command = plan

  variables {
    apply_policy_arns = ["AdministratorAccess"]
  }

  expect_failures = [var.apply_policy_arns]
}

run "ref_claim_must_be_ref_or_environment" {
  command = plan

  variables {
    apply_allowed_refs = ["main"]
  }

  expect_failures = [var.apply_allowed_refs]
}
