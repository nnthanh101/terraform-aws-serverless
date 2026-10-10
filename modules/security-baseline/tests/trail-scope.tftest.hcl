# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests with a mocked provider: no AWS account or credentials are used and nothing is applied.
# The account and organization IDs below are example fixtures, not tenant data.
# terraform test

mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_vpcs" {
    defaults = { ids = [] }
  }

  mock_data "aws_organizations_organization" {
    defaults = {
      id                = "o-example0001"
      master_account_id = "111122223333"
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:aa-example-1:111122223333:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = { arn = "arn:aws:sns:aa-example-1:111122223333:security-baseline-shared-alerts" }
  }
}

variables {
  account_id  = "111122223333"
  region      = "aa-example-1"
  alert_email = "security@example.com"
}

run "account_scope_is_the_default" {
  command = plan

  assert {
    condition     = var.trail_scope == "account" && aws_cloudtrail.this.is_organization_trail == false
    error_message = "the trail covers this account only unless trail_scope says organization"
  }
  assert {
    condition     = length(data.aws_organizations_organization.this) == 0
    error_message = "an account trail reads nothing from AWS Organizations"
  }
  assert {
    condition     = !strcontains(aws_s3_bucket_policy.trail.policy, "CloudTrailWriteOrganization")
    error_message = "an account trail adds no organization write statement to the bucket policy"
  }
  assert {
    condition     = aws_cloudtrail.this.is_multi_region_trail
    error_message = "every Region is mandatory in either scope"
  }
}

run "organization_scope" {
  command = plan

  variables {
    trail_scope                            = "organization"
    organization_service_access_principals = ["cloudtrail.amazonaws.com"]
  }

  assert {
    condition     = aws_cloudtrail.this.is_organization_trail && aws_cloudtrail.this.is_multi_region_trail
    error_message = "organization scope makes an organization trail that still covers every Region"
  }
  assert {
    condition     = strcontains(aws_s3_bucket_policy.trail.policy, "CloudTrailWriteOrganization") && strcontains(aws_s3_bucket_policy.trail.policy, "AWSLogs/${data.aws_organizations_organization.this[0].id}/*")
    error_message = "the bucket policy lets CloudTrail write under the organization ID"
  }
  assert {
    condition     = strcontains(aws_iam_role_policy.trail_logs.policy, "log-stream:*") && !strcontains(aws_iam_role_policy.trail_logs.policy, "${var.account_id}_CloudTrail_")
    error_message = "member account streams are not named by the management account ID, so the stream part is a wildcard"
  }
}

run "organization_scope_needs_cloudtrail_trusted_access" {
  command = plan

  variables {
    trail_scope = "organization"
  }

  expect_failures = [aws_cloudtrail.this]
}

run "organization_scope_refused_outside_the_management_account" {
  command = plan

  variables {
    trail_scope                            = "organization"
    organization_service_access_principals = ["cloudtrail.amazonaws.com"]
    account_id                             = "444455556666"
  }

  expect_failures = [aws_cloudtrail.this]
}

run "unknown_scope_is_refused" {
  command = plan

  variables {
    trail_scope = "region"
  }

  expect_failures = [var.trail_scope]
}
