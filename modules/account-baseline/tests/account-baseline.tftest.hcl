# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests with a mocked AWS provider: no account or credentials. Every input path of the module is planned once:
# the defaults, an existing OIDC provider, a second baseline beside the first (name_prefix), the numeric id claims, the
# customer-managed state key, three environments, a separate alert address, and each refused value.
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
  github_repository  = "example-org/example-app"
  default_branch     = "develop"
  budget_limit_usd   = 50
  notification_email = "owner@example.com"
}

run "defaults_build_the_whole_baseline" {
  command = plan

  assert {
    condition     = output.state_bucket_name == "123456789012-tfstate-ap-southeast-2" && output.backend_settings.use_lockfile && output.backend_settings.encrypt && output.backend_settings.kms_key_id == null
    error_message = "the state bucket is <account>-tfstate-<region> with S3-native locking, encrypted, and with no customer key by default"
  }

  assert {
    condition     = join(",", sort(keys(output.apply_role_arns))) == "dev,production" && join(",", sort(keys(output.plan_role_arns))) == "default,pr" && join(",", sort(keys(output.workload_boundary_policy_arns))) == "dev,production"
    error_message = "one apply role and one boundary per environment, and the two plan roles"
  }

  assert {
    condition     = endswith(output.oidc_provider_arn, "/created-by-this-plan") && output.budget_name == "platform-shared-monthly-cost"
    error_message = "the account gets its GitHub OIDC provider and a monthly budget"
  }

  assert {
    condition     = output.region_defaults["ap-southeast-2"].imds_tokens == "required" && output.region_defaults["ap-southeast-2"].ebs_encryption == null
    error_message = "IMDSv2 is required by default here, and EBS encryption is owned by the security baseline, not set twice"
  }

  assert {
    condition     = output.alerts_topic_arn != "" && output.trail_arn != ""
    error_message = "the alerts topic and the audit trail exist"
  }

  assert {
    condition     = output.protect_policy_names == ["SecurityBaselineProtect", "SecurityBaselineProtectWebAcl"] && output.controls.access_analyzer
    error_message = "the default security prefix keeps today's policy names, and the account analyzer is created"
  }
}

run "an_existing_oidc_provider_is_reused_not_created" {
  command = plan

  variables {
    existing_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = output.oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "with an existing provider the roles trust it and no second one is created"
  }
}

run "a_second_baseline_beside_the_first_gets_its_own_names" {
  command = plan

  variables {
    name_prefix          = "kit"
    security_name_prefix = "kit-baseline"
  }

  assert {
    condition     = output.state_bucket_name == "123456789012-kit-tfstate-ap-southeast-2" && output.budget_name == "kit-platform-shared-monthly-cost"
    error_message = "a prefix other than gha is put in front of the bucket and budget names"
  }

  assert {
    condition     = output.apply_role_names["dev"] == "kit-apply-dev" && output.apply_role_names["production"] == "kit-apply-production"
    error_message = "the apply roles are <prefix>-apply-<environment>"
  }

  assert {
    condition     = output.protect_policy_names == ["KitBaselineProtect", "KitBaselineProtectWebAcl"]
    error_message = "the two protection policy names follow security_name_prefix, so they cannot collide with the first baseline's"
  }
}

run "an_existing_access_analyzer_is_left_alone" {
  command = plan

  variables {
    access_analyzer_enabled = false
  }

  assert {
    condition     = output.controls.access_analyzer == false
    error_message = "access_analyzer_enabled false creates no analyzer"
  }
}

run "the_numeric_ids_and_the_subject_prefix_tighten_the_trust" {
  command = plan

  variables {
    github_repository_id  = "123456"
    github_owner_id       = "654321"
    github_subject_prefix = "repo:example-org@654321/example-app@123456"
  }

  assert {
    condition     = length(output.apply_role_arns) == 2
    error_message = "the roles plan with the id claims and the immutable subject prefix"
  }
}

run "a_customer_managed_state_key_is_an_input" {
  command = plan

  variables {
    create_state_kms_key = true
  }

  assert {
    condition     = output.backend_settings.kms_key_id == "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
    error_message = "backend_settings names the key when create_state_kms_key is true"
  }
}

run "three_environments_and_a_separate_alert_address" {
  command = plan

  variables {
    environments = ["dev", "uat", "production"]
    alert_email  = "security@example.com"
  }

  assert {
    condition     = join(",", sort(keys(output.apply_role_arns))) == "dev,production,uat"
    error_message = "every listed environment gets an apply role"
  }
}

run "api_gateway_logging_role_can_be_left_to_another_stack" {
  command = plan

  variables {
    enable_api_gateway_account = false
  }

  assert {
    condition     = length(output.apply_role_arns) == 2
    error_message = "the baseline plans with enable_api_gateway_account = false"
  }
}

run "a_wildcard_repository_is_refused" {
  command = plan

  variables {
    github_repository = "example-org/*"
  }

  expect_failures = [var.github_repository]
}

run "an_oidc_provider_of_another_account_is_refused" {
  command = plan

  variables {
    existing_oidc_provider_arn = "arn:aws:iam::444455556666:oidc-provider/token.actions.githubusercontent.com"
  }

  expect_failures = [var.existing_oidc_provider_arn]
}

run "production_must_be_named_in_one_account" {
  command = plan

  variables {
    production_environments = []
  }

  expect_failures = [var.production_environments]
}

run "small_account_cost_switches_reach_the_security_baseline" {
  command = plan

  variables {
    security_kms_key_enabled  = false
    access_log_bucket_enabled = false
    log_retention_days        = 90
  }

  assert {
    condition     = module.security.kms_key_arn == null
    error_message = "security_kms_key_enabled false creates no baseline key"
  }
}
