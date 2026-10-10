# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Tier 1: plans examples/single-account against a mocked AWS provider, so the example stays a
# working caller of the module: its provider block, inputs and outputs.
mock_provider "aws" {
  override_data {
    target = module.bootstrap.data.aws_partition.current
    values = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  override_data {
    target = module.bootstrap.data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  override_data {
    target = module.bootstrap.data.aws_region.current
    values = {
      region = "ap-southeast-2"
    }
  }
}

run "single_account_example_plans" {
  command = plan

  module {
    source = "./examples/single-account"
  }

  variables {
    account_id          = "123456789012"
    region              = "ap-southeast-2"
    github_repositories = ["acme/platform"]
    default_branch      = "develop"
    budget_limit_usd    = 250
    notification_email  = "finance@example.com"
    tags                = { owner = "platform-team" }
  }

  assert {
    condition     = output.backend_settings.bucket == "123456789012-tfstate-ap-southeast-2" && output.backend_settings.use_lockfile && output.backend_settings.encrypt
    error_message = "The example must report the default bucket with S3-native locking and encryption."
  }

  assert {
    condition     = join(",", sort(keys(output.apply_role_arns))) == "dev,production" && join(",", sort(keys(output.workload_boundary_policy_arns))) == "dev,production"
    error_message = "The example must create one apply role and one boundary per environment."
  }
}
