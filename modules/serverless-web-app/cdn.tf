# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# The static site on a private S3 bucket behind CloudFront with origin access control; the bucket stays private.
# Every response carries security headers; /api/* is routed to the HTTP API so browser and API share one origin.
# site_waf_enabled adds an AWS WAF web ACL, which CloudFront requires in us-east-1 whatever Region the rest uses.
# The site's files are uploaded to the bucket by the delivery pipeline after apply, then /index.html is invalidated.
# One account for dev and production: the apply role may create the origin access control and the response
# headers policy but never update or delete them (they take no tags), so a CSP change in dev is applied by the
# account administrator.

# ------------------------------------------------------------------ bucket

resource "aws_s3_bucket" "site" {
  # checkov:skip=CKV2_AWS_62:0001 nothing consumes object events for published site files
  # checkov:skip=CKV_AWS_18:0001 server access logs need a separate log bucket; add one when the spec asks for request logs
  # checkov:skip=CKV_AWS_144:0001 the site is rebuilt from the repository, so a second-Region copy adds cost and no recovery
  # checkov:skip=CKV_AWS_145:0001 public content served by CloudFront; a customer managed key controls no reader (see the encryption note below)
  bucket = "${local.name_prefix}-site-${var.account_id}"
}

resource "aws_s3_bucket_ownership_controls" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "site" {
  bucket                  = aws_s3_bucket.site.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "site" {
  bucket = aws_s3_bucket.site.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3, not a customer managed key: the objects are the public site that CloudFront serves to
# every viewer, so a key would control no reader. It would add a KMS call on every cache miss and a
# key policy for the CloudFront service. The application files bucket (s3.tf) uses its own key.
# trivy:ignore:AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "site" {
  bucket = aws_s3_bucket.site.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "site" {
  bucket = aws_s3_bucket.site.id

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

  depends_on = [aws_s3_bucket_versioning.site]
}

resource "aws_s3_bucket_policy" "site" {
  bucket = aws_s3_bucket.site.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudFrontReadsThroughOac"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.site.arn}/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.site.arn } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.site.arn, "${aws_s3_bucket.site.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.site]
}

# ------------------------------------------------------------------ CloudFront

data "aws_cloudfront_cache_policy" "site_static" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "site_api" {
  name = "Managed-CachingDisabled"
}

# Forwards viewer headers, cookies and query strings, but not Host: the API must see its own host name.
data "aws_cloudfront_origin_request_policy" "site_api" {
  name = "Managed-AllViewerExceptHostHeader"
}

resource "aws_cloudfront_origin_access_control" "site" {
  name                              = "${local.name_prefix}-site"
  description                       = "Signs requests from CloudFront to the ${local.name_prefix} site bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_response_headers_policy" "site" {
  # checkov:skip=CKV_AWS_259:0001 HSTS is on for two years with subdomains; the preload directive commits the whole domain, so the product team adds it deliberately
  name = "${local.name_prefix}-site-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      override                   = true
    }

    content_type_options {
      override = true
    }

    frame_options {
      frame_option = "DENY"
      override     = true
    }

    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }

    content_security_policy {
      content_security_policy = var.site_content_security_policy
      override                = true
    }
  }
}

resource "aws_wafv2_web_acl" "site" {
  # checkov:skip=CKV2_AWS_31:0001 sampled requests and metrics are on; full request logs need an aws-waf-logs- destination the budget approver sizes
  count  = var.site_waf_enabled ? 1 : 0
  region = "us-east-1"
  name   = "${local.name_prefix}-site"
  scope  = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-common-rule-set"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-site-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-known-bad-inputs"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-site-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.site_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name_prefix}-site-rate"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-site"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudfront_distribution" "site" {
  # checkov:skip=CKV_AWS_174:0001 the default CloudFront certificate fixes the protocol floor; set a custom domain with TLSv1.2_2021 when the spec names one
  # checkov:skip=CKV2_AWS_42:0001 the default CloudFront domain serves the site until the spec names a custom domain
  # checkov:skip=CKV_AWS_374:0001 the audience is not limited by country; the product team adds a restriction when the spec needs one
  # checkov:skip=CKV_AWS_310:0001 the origin is one bucket in one Region; failover needs a second copy the spec has not asked for
  # checkov:skip=CKV_AWS_86:0001 standard logs need a log bucket that allows ACLs; CloudFront metrics cover traffic until the spec asks for request logs
  # checkov:skip=CKV2_AWS_47:0001 the web ACL (site_waf_enabled) runs AWSManagedRulesKnownBadInputsRuleSet, which holds the Log4j rule; the scanner cannot follow the conditional attachment
  enabled             = true
  comment             = "${local.name_prefix}-site"
  default_root_object = "index.html"
  is_ipv6_enabled     = true
  http_version        = "http2and3"
  price_class         = var.site_price_class
  web_acl_id          = var.site_waf_enabled ? aws_wafv2_web_acl.site[0].arn : null

  origin {
    origin_id                = "site"
    domain_name              = aws_s3_bucket.site.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.site.id
  }

  origin {
    origin_id   = "api"
    domain_name = local.overlay.api_domain
    origin_path = local.overlay.api_path

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id           = "site"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.site_static.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id
  }

  ordered_cache_behavior {
    path_pattern               = "/api/*"
    target_origin_id           = "api"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.site_api.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.site_api.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.site.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
