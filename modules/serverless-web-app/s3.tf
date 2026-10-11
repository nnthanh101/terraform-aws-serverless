# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Private S3 bucket for application files: owner-enforced objects, all public access blocked, TLS 1.2 or later
# only, versioned, old versions removed after 30 days. Objects are encrypted with this bucket's own rotating
# customer managed key, which only the function's role uses, and only through S3. The key adds a fixed monthly
# fee; the S3 bucket key keeps KMS request charges low. With files_kms_key = false there is no key and the bucket
# uses S3-managed encryption (SSE-S3) at no cost.

data "aws_partition" "files" {}

resource "aws_kms_key" "files" {
  count = var.files_kms_key ? 1 : 0

  description             = "${local.name_prefix}-${var.files_bucket_label}: application files bucket"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  # The students' files are encrypted with this key: losing it loses them. A plan that destroys it is refused
  # whatever the caller sets. A literal on purpose: lifecycle arguments cannot be variables (change 0052).
  lifecycle {
    prevent_destroy = true
  }

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdministersKeyThroughIam"
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.files.partition}:iam::${var.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

resource "aws_kms_alias" "files" {
  count = var.files_kms_key ? 1 : 0

  name          = "alias/${local.name_prefix}-${var.files_bucket_label}"
  target_key_id = aws_kms_key.files[0].key_id
}

# The key and alias were single resources before files_kms_key existed; the callers' state moves to index 0.
moved {
  from = aws_kms_key.files
  to   = aws_kms_key.files[0]
}

moved {
  from = aws_kms_alias.files
  to   = aws_kms_alias.files[0]
}

resource "aws_s3_bucket" "files" {
  # checkov:skip=CKV2_AWS_62:0001 the function reads and writes these files directly; nothing consumes object events
  # checkov:skip=CKV_AWS_18:0001 server access logs need a separate log bucket; CloudTrail data events are the audit trail when the spec asks for one
  # checkov:skip=CKV_AWS_144:0001 one Region; replication doubles storage cost and the spec has not asked for it
  bucket = "${local.name_prefix}-${var.files_bucket_label}-${var.account_id}"

  # The students' files live here. A plan that destroys or replaces the bucket is refused whatever the caller sets.
  # A literal on purpose: lifecycle arguments cannot be variables (change 0052).
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "files" {
  bucket                  = aws_s3_bucket.files.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "files" {
  bucket = aws_s3_bucket.files.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    bucket_key_enabled = var.files_kms_key

    apply_server_side_encryption_by_default {
      sse_algorithm     = var.files_kms_key ? "aws:kms" : "AES256"
      kms_master_key_id = one(aws_kms_key.files[*].arn)
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "files" {
  bucket = aws_s3_bucket.files.id

  rule {
    id     = "expire-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.files]
}

resource "aws_s3_bucket_policy" "files" {
  bucket = aws_s3_bucket.files.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.files.arn, "${aws_s3_bucket.files.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOldTls"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.files.arn, "${aws_s3_bucket.files.arn}/*"]
        Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.files]
}

resource "aws_iam_role_policy" "files" {
  name = "files"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid      = "ListFiles"
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:ListBucketVersions"]
        Resource = aws_s3_bucket.files.arn
      },
      {
        Sid      = "ReadWriteFiles"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.files.arn}/*"
      },
      ], [for arn in aws_kms_key.files[*].arn : {
        Sid       = "FilesKeyThroughS3"
        Effect    = "Allow"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource  = arn
        Condition = { StringEquals = { "kms:ViaService" = "s3.${var.region}.${data.aws_partition.files.dns_suffix}" } }
    }])
  })
}
