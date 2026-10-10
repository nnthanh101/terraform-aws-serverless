# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Tier 1 snapshot test: the create_roles switch.
# Default (switch left out) is the shape every earlier caller has: provider plus both roles, same names, same outputs.
# create_roles = false is the provider-only shape the members root of the landing zone uses, so the provider has one
# owner in the account and bootstrap keeps its own pipeline roles.

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

run "default_keeps_both_roles" {
  command = plan

  variables {
    github_org          = "example-org"
    github_repositories = ["example-repo"]
    apply_policy_arns   = ["arn:aws:iam::aws:policy/AmazonS3FullAccess"]
  }

  assert {
    condition     = length(aws_iam_role.plan) == 1 && length(aws_iam_role.apply) == 1
    error_message = "with create_roles left out, the plan role and the apply role are created, one each"
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1
    error_message = "with create_oidc_provider left out, the provider is created"
  }

  assert {
    condition     = output.plan_role_name == "github-actions-plan" && output.apply_role_name == "github-actions-apply"
    error_message = "role names keep their defaults, so a caller that has not set the switch sees no change"
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.plan) == 1 && length(aws_iam_role_policy_attachment.apply) == 1
    error_message = "one attachment per listed policy ARN, as before"
  }
}

run "roles_off_keeps_only_the_provider" {
  command = plan

  variables {
    github_org          = "example-org"
    github_repositories = ["example-repo"]
    create_roles        = false
  }

  assert {
    condition     = length(aws_iam_role.plan) == 0 && length(aws_iam_role.apply) == 0
    error_message = "create_roles = false creates no role"
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.plan) == 0 && length(aws_iam_role_policy_attachment.apply) == 0
    error_message = "create_roles = false creates no attachment"
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 1
    error_message = "create_roles = false still creates the provider: it is the one resource this module owns for the account"
  }

  assert {
    condition     = output.plan_role_arn == null && output.apply_role_arn == null && output.plan_role_name == null && output.apply_role_name == null
    error_message = "role outputs are null when no role is created"
  }

  assert {
    condition     = output.oidc_provider_arn != null
    error_message = "the provider ARN is still an output: bootstrap in the same account takes it"
  }
}

run "roles_on_still_needs_an_apply_policy" {
  command = plan

  variables {
    github_org          = "example-org"
    github_repositories = ["example-repo"]
  }

  expect_failures = [var.apply_policy_arns]
}
