# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests of the application files bucket and its key, with mocked providers. No AWS account or credentials are used.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

mock_provider "archive" {}

override_resource {
  target          = aws_s3_bucket.files
  override_during = plan
  values = {
    arn = "arn:aws:s3:::orders-dev-files-111122223333"
  }
}

override_resource {
  target          = aws_kms_key.files
  override_during = plan
  values = {
    arn    = "arn:aws:kms:aa-example-1:111122223333:key/11111111-1111-1111-1111-111111111111"
    key_id = "11111111-1111-1111-1111-111111111111"
  }
}

variables {
  account_id               = "111122223333"
  region                   = "aa-example-1"
  environment              = "dev"
  service                  = "orders"
  permissions_boundary_arn = "arn:aws:iam::111122223333:policy/platform-dev-workload-boundary"
  alarm_topic_arn          = "arn:aws:sns:aa-example-1:111122223333:orders-dev-alarms"
  source_dir               = "build"
  site_source_dir          = "tests/fixtures/site"
}

run "private_bucket" {
  command = plan

  assert {
    condition     = aws_s3_bucket.files.bucket == "orders-dev-files-111122223333"
    error_message = "The bucket name must follow <service>-<environment>-files-<account>."
  }

  assert {
    condition = (
      aws_s3_bucket_ownership_controls.files.rule[0].object_ownership == "BucketOwnerEnforced" &&
      aws_s3_bucket_public_access_block.files.block_public_acls &&
      aws_s3_bucket_public_access_block.files.block_public_policy &&
      aws_s3_bucket_public_access_block.files.ignore_public_acls &&
      aws_s3_bucket_public_access_block.files.restrict_public_buckets
    )
    error_message = "The bucket must enforce owner objects and block all public access."
  }

  assert {
    condition     = aws_s3_bucket_versioning.files.versioning_configuration[0].status == "Enabled"
    error_message = "The bucket must be versioned."
  }

  assert {
    condition = anytrue([for s in jsondecode(aws_s3_bucket_policy.files.policy).Statement :
    s.Effect == "Deny" && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"])
    error_message = "The bucket policy must deny requests without TLS."
  }
}

run "customer_managed_key" {
  command = plan

  assert {
    condition = alltrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.files.rule :
      r.bucket_key_enabled && r.apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms" &&
      r.apply_server_side_encryption_by_default[0].kms_master_key_id == "arn:aws:kms:aa-example-1:111122223333:key/11111111-1111-1111-1111-111111111111"
    ])
    error_message = "The bucket must use SSE-KMS with its own customer managed key and an S3 bucket key."
  }

  assert {
    condition     = aws_kms_key.files.enable_key_rotation && aws_kms_key.files.deletion_window_in_days == 30
    error_message = "The bucket key must rotate and keep a 30-day deletion window."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.files.policy).Statement : s
      if s.Sid == "FilesKeyThroughS3" && s.Effect == "Allow" &&
      s.Resource == "arn:aws:kms:aa-example-1:111122223333:key/11111111-1111-1111-1111-111111111111" &&
      s.Condition.StringEquals["kms:ViaService"] == "s3.aa-example-1.amazonaws.com"
    ]) == 1
    error_message = "The function may use the bucket key only through S3 in its own Region."
  }
}
