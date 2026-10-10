# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# The trail: every Region, management events, log file validation, encrypted with the baseline key,
# delivered to a bucket that only CloudTrail writes and to a log group the alarms read.

# ------------------------------------------------------------------ trail bucket

resource "aws_s3_bucket" "trail" {
  # checkov:skip=CKV_AWS_144:0024 one Region by design; versioning, prevent_destroy and log file validation protect the files
  # checkov:skip=CKV2_AWS_62:0024 nothing consumes object events from the trail bucket
  bucket = local.trail_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  bucket                  = aws_s3_bucket.trail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "trail" {
  bucket = aws_s3_bucket.trail.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  rule {
    bucket_key_enabled = var.kms_key_enabled

    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_enabled ? "aws:kms" : "AES256"
      kms_master_key_id = local.kms_arn
    }
  }
}

# AWS Config, when on, delivers under config/AWSLogs/<account>/Config/ as its service principal, for
# this account only (Config developer guide, "Permissions for the Amazon S3 Bucket for the AWS Config
# Delivery Channel"): its service-linked role cannot write to S3.
locals {
  config_bucket_statements = [
    {
      Sid       = "ConfigBucketPermissionsCheck"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "s3:GetBucketAcl"
      Resource  = local.trail_bucket_arn
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    },
    {
      Sid       = "ConfigBucketExistenceCheck"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "s3:ListBucket"
      Resource  = local.trail_bucket_arn
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    },
    {
      Sid       = "ConfigBucketDelivery"
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "s3:PutObject"
      Resource  = "${local.trail_bucket_arn}/config/AWSLogs/${var.account_id}/Config/*"
      Condition = {
        StringEquals = {
          "s3:x-amz-acl"      = "bucket-owner-full-control"
          "aws:SourceAccount" = var.account_id
        }
      }
    },
  ]
}

# An organization trail also writes each member account's files under AWSLogs/<organization id>/.
locals {
  org_bucket_statements = local.org_trail ? [{
    Sid       = "CloudTrailWriteOrganization"
    Effect    = "Allow"
    Principal = { Service = "cloudtrail.amazonaws.com" }
    Action    = "s3:PutObject"
    Resource  = "${local.trail_bucket_arn}/AWSLogs/${data.aws_organizations_organization.this[0].id}/*"
    Condition = {
      StringEquals = {
        "s3:x-amz-acl"  = "bucket-owner-full-control"
        "aws:SourceArn" = local.trail_arn
      }
    }
  }] : []
}

resource "aws_s3_bucket_policy" "trail" {
  bucket = aws_s3_bucket.trail.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.trail_bucket_arn, "${local.trail_bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOldTls"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.trail_bucket_arn, "${local.trail_bucket_arn}/*"]
        Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
      },
      {
        Sid       = "CloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = local.trail_bucket_arn
        Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
      },
      {
        Sid       = "CloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${local.trail_bucket_arn}/AWSLogs/${var.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.trail_arn
          }
        }
      },
      {
        # The delivery pipeline and its workloads never change this bucket or its files.
        Sid       = "DenyChangesByPipelineRoles"
        Effect    = "Deny"
        Principal = "*"
        Action    = concat(local.bucket_settings, local.log_object_writes)
        Resource  = [local.trail_bucket_arn, "${local.trail_bucket_arn}/*"]
        Condition = { ArnLike = { "aws:PrincipalArn" = local.pipeline_principals } }
      },
    ], local.org_bucket_statements, [for s in local.config_bucket_statements : s if var.config_enabled])
  })

  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  bucket = aws_s3_bucket.trail.id

  # No Glacier transition: CloudTrail files are a few KB, and S3 moves nothing under 128 KB.
  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.trail]
}

resource "aws_s3_bucket_logging" "trail" {
  count         = local.access_log_on ? 1 : 0
  bucket        = aws_s3_bucket.trail.id
  target_bucket = aws_s3_bucket.access_logs[count.index].id
  target_prefix = "trail/"

  depends_on = [aws_s3_bucket_policy.access_logs]
}

# ------------------------------------------------------------------ access-log bucket

resource "aws_s3_bucket" "access_logs" {
  # checkov:skip=CKV_AWS_18:0024 a log destination must not log to itself
  # checkov:skip=CKV_AWS_144:0024 one Region by design; the files it holds describe reads of the trail bucket
  # checkov:skip=CKV_AWS_145:0024 S3 delivers server access logs only to buckets encrypted with SSE-S3
  # checkov:skip=CKV2_AWS_62:0024 nothing consumes object events from the access-log bucket
  count  = local.access_log_on ? 1 : 0
  bucket = local.access_log_bucket
}

resource "aws_s3_bucket_ownership_controls" "access_logs" {
  count  = local.access_log_on ? 1 : 0
  bucket = aws_s3_bucket.access_logs[count.index].id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  count                   = local.access_log_on ? 1 : 0
  bucket                  = aws_s3_bucket.access_logs[count.index].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "access_logs" {
  count  = local.access_log_on ? 1 : 0
  bucket = aws_s3_bucket.access_logs[count.index].id

  versioning_configuration {
    status = "Enabled"
  }
}

# 0024 SSE-S3, not the baseline key: S3 delivers server access logs only to SSE-S3 destinations.
# trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  count  = local.access_log_on ? 1 : 0
  bucket = aws_s3_bucket.access_logs[count.index].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "access_logs" {
  count  = local.access_log_on ? 1 : 0
  bucket = aws_s3_bucket.access_logs[count.index].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.access_log_bucket_arn, "${local.access_log_bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOldTls"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.access_log_bucket_arn, "${local.access_log_bucket_arn}/*"]
        Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
      },
      {
        Sid       = "S3ServerAccessLogs"
        Effect    = "Allow"
        Principal = { Service = "logging.s3.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${local.access_log_bucket_arn}/trail/*"
        Condition = {
          ArnLike      = { "aws:SourceArn" = local.trail_bucket_arn }
          StringEquals = { "aws:SourceAccount" = var.account_id }
        }
      },
      {
        Sid       = "DenyChangesByPipelineRoles"
        Effect    = "Deny"
        Principal = "*"
        Action    = concat(local.bucket_settings, local.log_object_writes)
        Resource  = [local.access_log_bucket_arn, "${local.access_log_bucket_arn}/*"]
        Condition = { ArnLike = { "aws:PrincipalArn" = local.pipeline_principals } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.access_logs]
}

resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  count  = local.access_log_on ? 1 : 0
  bucket = aws_s3_bucket.access_logs[count.index].id

  rule {
    id     = "expire-logs"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.access_logs]
}

# ------------------------------------------------------------------ log group and delivery role

resource "aws_cloudwatch_log_group" "trail" {
  name              = local.log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = local.kms_arn
}

resource "aws_iam_role" "trail_logs" {
  name        = "${local.prefix}-trail-logs"
  description = "CloudTrail delivers ${local.trail_name} events to ${local.log_group_name}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "CloudTrailOnly"
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
    }]
  })
}

resource "aws_iam_role_policy" "trail_logs" {
  name = "DeliverToLogGroup"
  role = aws_iam_role.trail_logs.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "TrailStreams"
      Effect = "Allow"
      Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
      # An organization trail also streams its member accounts' events, named by their own account IDs.
      Resource = "${local.log_group_arn}:log-stream:${local.org_trail ? "" : "${var.account_id}_CloudTrail_"}*"
    }]
  })
}

# ------------------------------------------------------------------ trail

resource "aws_cloudtrail" "this" {
  # checkov:skip=CKV_AWS_252:0024 a notice per delivered file would flood the alerts topic; the alarms read the log group instead
  name           = local.trail_name
  s3_bucket_name = aws_s3_bucket.trail.bucket
  # Every Region is a mandatory control: a single-Region trail misses activity in the Regions nobody watches.
  is_multi_region_trail         = true
  is_organization_trail         = local.org_trail
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = local.kms_arn
  cloud_watch_logs_group_arn    = "${local.log_group_arn}:*"
  cloud_watch_logs_role_arn     = aws_iam_role.trail_logs.arn

  # With no bucket named there is no selector: CloudTrail's default records every management event,
  # read and write. The provider (6.66.0) reads a lone default selector back as none, so writing one
  # would show a change on every plan. A named bucket adds object events to that same selector.
  dynamic "event_selector" {
    for_each = length(var.s3_data_event_bucket_names) > 0 ? [var.s3_data_event_bucket_names] : []

    content {
      read_write_type           = "All"
      include_management_events = true

      data_resource {
        type   = "AWS::S3::Object"
        values = [for b in event_selector.value : "arn:${local.partition}:s3:::${b}/"]
      }
    }
  }

  depends_on = [aws_s3_bucket_policy.trail, aws_cloudwatch_log_group.trail, aws_iam_role_policy.trail_logs]

  lifecycle {
    precondition {
      condition     = !local.org_trail || contains(var.organization_service_access_principals, "cloudtrail.amazonaws.com")
      error_message = "The organization has no CloudTrail trusted access on record. Set organization_service_access_principals to module.organizations.service_access_principals and add cloudtrail.amazonaws.com to service_access_principals in the organizations module (or enable cloudtrail.amazonaws.com trusted access yourself first)."
    }

    precondition {
      condition     = !local.org_trail || var.account_id == data.aws_organizations_organization.this[0].master_account_id
      error_message = "Run security-baseline from the management account: only it can create an organization trail."
    }
  }
}
