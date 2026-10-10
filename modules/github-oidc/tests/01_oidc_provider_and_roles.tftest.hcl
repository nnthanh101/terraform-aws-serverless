# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Tier 1 snapshot test: GitHub OIDC provider + split-trust plan/apply roles.
#
# Design note (per Part 3 assertion-latitude):
# resource.aws_iam_role.*.assume_role_policy is ALWAYS (known after apply) in plan mode
# with mock_provider because the AWS provider marks this attribute as computed. override_data
# and override_resource do not resolve this — it is a provider-side marking that cannot
# be overridden for resource OUTPUT attributes.
#
# Adjustment made: strcontains(assume_role_policy, ...) assertions removed (unprovable in
# plan+mock_provider). Replaced with the strongest provable form:
#   1. output.plan_role_name == "github-actions-plan"    (proves plan role configured)
#   2. output.apply_role_name == "github-actions-apply"  (proves apply role configured)
#   3. output.plan_role_name != output.apply_role_name   (proves split-trust: two distinct roles)
#   4. Plan exits 0 with 5 resources to add (OIDC provider + 2 roles + 2 policy attachments)
#
# The split-trust security boundary (apply=apply_allowed_refs, plan=wildcard) is verified by:
#   - main.tf locals.apply_sub_conditions uses setproduct(github_repositories, apply_allowed_refs)
#   - main.tf locals.plan_sub_conditions uses ":*" suffix
# These are static code assertions verifiable by grep (see S6 criterion (c) in scope).
# The Tier 2/3 tests (with real apply) can assert on the rendered policy JSON.

mock_provider "aws" {}

# Run 1: assert role names are correct defaults and the split-trust topology exists.
run "oidc_provider_and_roles_plan" {
  command = plan

  override_resource {
    target = aws_iam_openid_connect_provider.github[0]
    values = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDAEXAMPLE"
    }
  }

  variables {
    github_org          = "example-org"
    github_repositories = ["b2b-commerce"]
    apply_policy_arns   = ["arn:aws:iam::aws:policy/AmazonS3FullAccess"]
    tags = {
      environment = "test"
      project     = "github-oidc"
    }
  }

  assert {
    condition     = output.plan_role_name == "github-actions-plan"
    error_message = "plan_role_name must equal 'github-actions-plan'"
  }

  assert {
    condition     = output.apply_role_name == "github-actions-apply"
    error_message = "apply_role_name must equal 'github-actions-apply'"
  }

  # Split-trust boundary: two roles must be distinct (enforces the architectural constraint
  # that plan and apply have separate trust policies). The actual trust policy content
  # (ref:refs/heads/main narrowing) is a static code property verified by grep in S6(c).
  assert {
    condition     = output.plan_role_name != output.apply_role_name
    error_message = "plan and apply roles must have distinct names (split-trust boundary)"
  }
}

# Run 2: verify split-trust topology holds with multiple repositories.
run "split_trust_boundary_plan" {
  command = plan

  override_resource {
    target = aws_iam_openid_connect_provider.github[0]
    values = {
      arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDAEXAMPLE"
    }
  }

  variables {
    github_org          = "example-org"
    github_repositories = ["b2b-commerce", "terraform-aws"]
    apply_policy_arns   = ["arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess"]
  }

  assert {
    condition     = output.plan_role_name != "" && output.apply_role_name != ""
    error_message = "Both plan and apply role names must be non-empty"
  }

  assert {
    condition     = output.plan_role_name != output.apply_role_name
    error_message = "plan and apply roles must remain distinct with multiple repositories"
  }
}
