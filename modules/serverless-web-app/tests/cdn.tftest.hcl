# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests of the site bucket and CloudFront distribution, with mocked providers. No AWS account or credentials are used.

mock_provider "aws" {}

mock_provider "archive" {}

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

run "private_site_behind_cloudfront" {
  command = plan

  assert {
    condition = (
      aws_cloudfront_origin_access_control.site.origin_access_control_origin_type == "s3" &&
      aws_cloudfront_origin_access_control.site.signing_behavior == "always" &&
      aws_cloudfront_origin_access_control.site.signing_protocol == "sigv4"
    )
    error_message = "CloudFront must read the bucket through origin access control."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.site.block_public_policy && aws_s3_bucket_public_access_block.site.restrict_public_buckets
    error_message = "The site bucket must stay private."
  }

  assert {
    condition = (
      aws_cloudfront_distribution.site.default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https" &&
      aws_cloudfront_response_headers_policy.site.security_headers_config[0].frame_options[0].frame_option == "DENY"
    )
    error_message = "The site must redirect to HTTPS and send security headers."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.site.ordered_cache_behavior) == 1
    error_message = "The distribution routes /api/* to the API."
  }

  assert {
    condition     = length(aws_wafv2_web_acl.site) == 0
    error_message = "AWS WAF is off unless site_waf_enabled is set."
  }
}

run "waf_in_us_east_1" {
  command = plan

  variables {
    site_waf_enabled = true
  }

  assert {
    condition     = aws_wafv2_web_acl.site[0].scope == "CLOUDFRONT" && aws_wafv2_web_acl.site[0].region == "us-east-1"
    error_message = "A CloudFront web ACL must be created in us-east-1 with scope CLOUDFRONT."
  }
}

run "site_digest_follows_the_files" {
  command = plan

  assert {
    condition     = contains(local.site_files, "index.html") && !contains(local.site_files, "Dockerfile") && !contains(local.site_files, "nginx.conf") && !contains(local.site_files, "_nocache_server.py")
    error_message = "The site digest covers the published files and leaves out the container and preview files."
  }
}
