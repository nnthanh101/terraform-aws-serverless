# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Tier 1: plans examples/management-account against a mocked AWS provider: a management account gets no pipeline
# role.
mock_provider "aws" {
  override_data {
    target = module.bootstrap.data.aws_partition.current
    values = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  override_data {
    target = module.bootstrap.data.aws_caller_identity.current
    values = { account_id = "123456789012" }
  }
  override_data {
    target = module.bootstrap.data.aws_region.current
    values = { region = "ap-southeast-2" }
  }
  override_resource {
    target          = module.bootstrap.aws_kms_key.state
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
  github_repository  = "acme/platform"
  default_branch     = "develop"
  state_bucket_name  = "platform-shared-tfstate-123456789012"
  budget_limit_usd   = 50
  notification_email = "finance@example.com"
  change_id          = "0021"
}

run "management_account_has_no_pipeline_role" {
  command = plan

  module {
    source = "./examples/management-account"
  }

  assert {
    condition     = length(module.bootstrap.plan_role_arns) == 0 && length(module.bootstrap.apply_role_arns) == 0 && module.bootstrap.oidc_provider_arn == null
    error_message = "a management account gets no GitHub trust and no plan or apply role"
  }
  assert {
    condition     = output.state_region == "ap-southeast-2" && output.state_bucket_name == "platform-shared-tfstate-123456789012"
    error_message = "the outputs the tenant settings are filled from are all there"
  }
}
