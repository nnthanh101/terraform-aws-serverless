# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Tier 1: create_state_kms_key. On (the default) keeps the customer-managed key and its deny statements;
# off uses the bucket default SSE-S3, with no key, no alias, no key statement in any policy.
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
  account_id          = "123456789012"
  region              = "ap-southeast-2"
  github_repositories = ["acme/platform"]
  default_branch      = "develop"
  state_bucket_name   = "acme-shared-tfstate-123456789012"
  budget_limit_usd    = 250
  notification_email  = "finance@example.com"
  change_id           = "0001"
}

run "key_on_by_default" {
  command = plan

  assert {
    condition     = length(aws_kms_key.state) == 1 && length(aws_kms_alias.state) == 1
    error_message = "By default the state key and its alias are created."
  }

  assert {
    condition     = one([for r in aws_s3_bucket_server_side_encryption_configuration.state.rule : one(r.apply_server_side_encryption_by_default).sse_algorithm]) == "aws:kms"
    error_message = "By default the state bucket encrypts with aws:kms."
  }

  assert {
    condition     = strcontains(aws_s3_bucket_policy.state.policy, "DenyNonKmsUploads") && strcontains(aws_s3_bucket_policy.state.policy, "DenyOtherKmsKeys")
    error_message = "By default the bucket policy refuses uploads that do not use the state key."
  }
}

run "key_off_uses_sse_s3" {
  command = plan

  variables {
    create_state_kms_key = false
  }

  assert {
    condition     = length(aws_kms_key.state) == 0 && length(aws_kms_alias.state) == 0
    error_message = "With create_state_kms_key = false no key and no alias are created."
  }

  assert {
    condition     = one([for r in aws_s3_bucket_server_side_encryption_configuration.state.rule : one(r.apply_server_side_encryption_by_default).sse_algorithm]) == "AES256"
    error_message = "With no key the state bucket encrypts with SSE-S3 (AES256)."
  }

  assert {
    condition     = !strcontains(aws_s3_bucket_policy.state.policy, "DenyNonKmsUploads") && !strcontains(aws_s3_bucket_policy.state.policy, "DenyOtherKmsKeys") && strcontains(aws_s3_bucket_policy.state.policy, "DenyInsecureTransport") && strcontains(aws_s3_bucket_policy.state.policy, "DenyOldTls")
    error_message = "With no key the bucket policy drops the key statements and keeps the TLS statements."
  }

  assert {
    condition     = output.state_kms_key_arn == null && output.backend_settings.kms_key_id == null && output.backend_settings.encrypt == true
    error_message = "With no key the outputs are null and the backend still asks for encryption."
  }
}

run "key_off_bucket_policy_pins_sse_s3" {
  command = plan

  variables {
    create_state_kms_key = false
  }

  assert {
    condition = [for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s.Condition if s.Sid == "DenyNonSseS3Uploads"][0] == {
      StringNotEquals = { "s3:x-amz-server-side-encryption" = "AES256" }
      Null            = { "s3:x-amz-server-side-encryption" = "false" }
    }
    error_message = "Key off, an upload that names an algorithm other than AES256 is denied."
  }

  assert {
    condition = [for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s.Condition if s.Sid == "DenySseCUploads"][0] == {
      Null = { "s3:x-amz-server-side-encryption-customer-algorithm" = "false" }
    }
    error_message = "Key off, an upload with a customer-supplied key (SSE-C) is denied."
  }

  assert {
    condition     = alltrue([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s.Action == "s3:PutObject" && s.Effect == "Deny" if contains(["DenyNonSseS3Uploads", "DenySseCUploads"], s.Sid)])
    error_message = "The two statements are denies on s3:PutObject only."
  }

  assert {
    condition = [for s in jsondecode(aws_iam_role_policy.plan_state["default"].policy).Statement : s.Condition if s.Sid == "SavePlans"][0] == {
      StringEqualsIfExists = { "s3:x-amz-server-side-encryption" = "AES256" }
      Null                 = { "s3:x-amz-server-side-encryption-customer-algorithm" = "true" }
    }
    error_message = "Key off, the SavePlans grant allows no header or AES256, and no customer-supplied key."
  }
}

run "key_on_bucket_policy_is_unchanged" {
  command = plan

  assert {
    condition     = !strcontains(aws_s3_bucket_policy.state.policy, "DenyNonSseS3Uploads") && !strcontains(aws_s3_bucket_policy.state.policy, "DenySseCUploads")
    error_message = "With the key on, the SSE-S3 statements are absent."
  }

  assert {
    condition     = [for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s.Sid] == ["DenyInsecureTransport", "DenyOldTls", "DenyNonKmsUploads", "DenyKmsWithoutStateKey", "DenyOtherKmsKeys", "DenyBucketSettingsToPipelineRoles"]
    error_message = "With the key on, the bucket policy keeps exactly its six statements in order."
  }

  assert {
    condition = [for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s.Condition if s.Sid == "DenyNonKmsUploads"][0] == {
      StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
      Null            = { "s3:x-amz-server-side-encryption" = "false" }
    }
    error_message = "With the key on, DenyNonKmsUploads is unchanged."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.plan_state["default"].policy).Statement : s.Condition.StringEquals if s.Sid == "SavePlans"][0]["s3:x-amz-server-side-encryption"] == "aws:kms"
    error_message = "With the key on, SavePlans still requires aws:kms with the state key."
  }
}
