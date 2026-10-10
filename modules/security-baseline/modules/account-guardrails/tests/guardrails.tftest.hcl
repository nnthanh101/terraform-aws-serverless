# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests with a mocked provider: no AWS account or credentials are used and nothing is applied.
# The account IDs below are obvious fixtures, not tenant data.
# terraform test

mock_provider "aws" {
  override_during = plan

  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
}

variables {
  account_id = "111111111111"
  regions    = ["ap-southeast-2", "ap-southeast-4", "us-east-1"]
}

run "defaults_s3_pab_all_four_true" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_account_public_access_block.this[0].block_public_acls,
      aws_s3_account_public_access_block.this[0].block_public_policy,
      aws_s3_account_public_access_block.this[0].ignore_public_acls,
      aws_s3_account_public_access_block.this[0].restrict_public_buckets,
    ])
    error_message = "All four S3 account public access block settings must be true."
  }

  assert {
    condition     = aws_s3_account_public_access_block.this[0].account_id == "111111111111"
    error_message = "The S3 block must target account_id."
  }
}

run "password_policy_strength" {
  command = plan

  assert {
    condition = (
      aws_iam_account_password_policy.this[0].minimum_password_length >= 14 &&
      aws_iam_account_password_policy.this[0].password_reuse_prevention == 24 &&
      aws_iam_account_password_policy.this[0].max_password_age == 0 &&
      aws_iam_account_password_policy.this[0].hard_expiry == false
    )
    error_message = "Password policy needs length >= 14, reuse prevention 24 and no expiry."
  }

  assert {
    condition = alltrue([
      aws_iam_account_password_policy.this[0].require_lowercase_characters,
      aws_iam_account_password_policy.this[0].require_uppercase_characters,
      aws_iam_account_password_policy.this[0].require_numbers,
      aws_iam_account_password_policy.this[0].require_symbols,
    ])
    error_message = "All four character classes must be required."
  }
}

run "one_resource_per_region" {
  command = plan

  assert {
    condition = alltrue([
      length(aws_ebs_encryption_by_default.this) == 3,
      length(aws_ebs_snapshot_block_public_access.this) == 3,
      length(aws_ec2_image_block_public_access.this) == 3,
      length(aws_ec2_instance_metadata_defaults.this) == 3,
    ])
    error_message = "Each regional resource must exist once per Region."
  }
}

run "region_argument_matches_key" {
  command = plan

  assert {
    condition = alltrue([
      for k, r in aws_ebs_encryption_by_default.this : r.region == k
    ])
    error_message = "ebs encryption region must equal its key."
  }

  assert {
    condition = alltrue([
      for k, r in aws_ebs_snapshot_block_public_access.this : r.region == k
    ])
    error_message = "snapshot block region must equal its key."
  }

  assert {
    condition = alltrue([
      for k, r in aws_ec2_image_block_public_access.this : r.region == k
    ])
    error_message = "AMI block region must equal its key."
  }

  assert {
    condition = alltrue([
      for k, r in aws_ec2_instance_metadata_defaults.this : r.region == k
    ])
    error_message = "IMDS defaults region must equal its key."
  }
}

run "ebs_encryption_enabled_everywhere" {
  command = plan

  assert {
    condition     = alltrue([for r in aws_ebs_encryption_by_default.this : r.enabled])
    error_message = "EBS encryption by default must be enabled in every Region."
  }
}

run "snapshot_block_all_sharing_default" {
  command = plan

  assert {
    condition     = alltrue([for r in aws_ebs_snapshot_block_public_access.this : r.state == "block-all-sharing"])
    error_message = "Snapshots must default to block-all-sharing."
  }
}

run "snapshot_block_new_sharing_allowed" {
  command = plan

  variables {
    snapshot_block_public_access = "block-new-sharing"
  }

  assert {
    condition     = alltrue([for r in aws_ebs_snapshot_block_public_access.this : r.state == "block-new-sharing"])
    error_message = "block-new-sharing must be accepted and applied."
  }
}

run "ami_block_new_sharing_everywhere" {
  command = plan

  assert {
    condition     = alltrue([for r in aws_ec2_image_block_public_access.this : r.state == "block-new-sharing"])
    error_message = "AMI public access must be blocked in every Region."
  }
}

run "imds_required_hop_2_default" {
  command = plan

  assert {
    condition = alltrue([
      for r in aws_ec2_instance_metadata_defaults.this :
      r.http_tokens == "required" && r.http_put_response_hop_limit == 2
    ])
    error_message = "IMDS defaults must require tokens with hop limit 2."
  }
}

run "imds_optional_switch" {
  command = plan

  variables {
    imds_v2_required = false
    imds_hop_limit   = 1
  }

  assert {
    condition = alltrue([
      for r in aws_ec2_instance_metadata_defaults.this :
      r.http_tokens == "no-preference" && r.http_put_response_hop_limit == 1
    ])
    error_message = "imds_v2_required = false must give no-preference and honour the hop limit."
  }
}

run "account_mismatch_fails_with_s3_switch_off_password_policy_on" {
  command = plan

  variables {
    account_id                    = "222222222222"
    create_s3_public_access_block = false
    create_ebs_encryption         = false
    create_snapshot_block         = false
    create_ami_block              = false
    create_imds_defaults          = false
  }

  expect_failures = [aws_iam_account_password_policy.this]
}

run "account_mismatch_fails_with_s3_switch_off_regional_on" {
  command = plan

  variables {
    account_id                    = "222222222222"
    create_s3_public_access_block = false
    create_password_policy        = false
    create_snapshot_block         = false
    create_ami_block              = false
    create_imds_defaults          = false
  }

  expect_failures = [aws_ebs_encryption_by_default.this]
}

run "account_mismatch_fails" {
  command = plan

  variables {
    account_id = "222222222222"
  }

  expect_failures = [
    aws_s3_account_public_access_block.this,
    aws_iam_account_password_policy.this,
    aws_ebs_encryption_by_default.this,
    aws_ebs_snapshot_block_public_access.this,
    aws_ec2_image_block_public_access.this,
    aws_ec2_instance_metadata_defaults.this,
  ]
}

run "invalid_account_id_rejected" {
  command = plan

  variables {
    account_id = "12345"
  }

  expect_failures = [var.account_id]
}

run "empty_regions_rejected" {
  command = plan

  variables {
    regions = []
  }

  expect_failures = [var.regions]
}

run "duplicate_region_rejected" {
  command = plan

  variables {
    regions = ["us-east-1", "us-east-1"]
  }

  expect_failures = [var.regions]
}

run "malformed_region_rejected" {
  command = plan

  variables {
    regions = ["Sydney"]
  }

  expect_failures = [var.regions]
}

run "password_length_below_14_rejected" {
  command = plan

  variables {
    password_minimum_length = 8
  }

  expect_failures = [var.password_minimum_length]
}

run "snapshot_unblocked_rejected" {
  command = plan

  variables {
    snapshot_block_public_access = "unblocked"
  }

  expect_failures = [var.snapshot_block_public_access]
}

run "hop_limit_out_of_range_rejected" {
  command = plan

  variables {
    imds_hop_limit = 65
  }

  expect_failures = [var.imds_hop_limit]
}

run "all_off_creates_nothing" {
  command = plan

  variables {
    create_s3_public_access_block = false
    create_password_policy        = false
    create_ebs_encryption         = false
    create_snapshot_block         = false
    create_ami_block              = false
    create_imds_defaults          = false
  }

  assert {
    condition = alltrue([
      length(aws_s3_account_public_access_block.this) == 0,
      length(aws_iam_account_password_policy.this) == 0,
      length(aws_ebs_encryption_by_default.this) == 0,
      length(aws_ebs_snapshot_block_public_access.this) == 0,
      length(aws_ec2_image_block_public_access.this) == 0,
      length(aws_ec2_instance_metadata_defaults.this) == 0,
    ])
    error_message = "With every switch off the plan must create no resource."
  }

  assert {
    condition     = output.account_id == "111111111111" && length(output.settings) == 3 && alltrue([for r, s in output.settings : s.ebs_encryption == null && s.snapshot_bpa == null && s.ami_bpa == null && s.imds_tokens == null])
    error_message = "With every switch off the outputs must list the Regions with null settings."
  }
}

run "each_switch_removes_only_its_resource" {
  command = plan

  variables {
    create_password_policy = false
    create_ami_block       = false
  }

  assert {
    condition = alltrue([
      length(aws_s3_account_public_access_block.this) == 1,
      length(aws_iam_account_password_policy.this) == 0,
      length(aws_ebs_encryption_by_default.this) == 3,
      length(aws_ebs_snapshot_block_public_access.this) == 3,
      length(aws_ec2_image_block_public_access.this) == 0,
      length(aws_ec2_instance_metadata_defaults.this) == 3,
    ])
    error_message = "A switch set to false must remove exactly its own resource."
  }
}

run "outputs_summarise_each_region" {
  command = plan

  assert {
    condition     = length(output.settings) == 3 && output.settings["us-east-1"].imds_tokens == "required"
    error_message = "settings must list every Region with its IMDS mode."
  }
}
