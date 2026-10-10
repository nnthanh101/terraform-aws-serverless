# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# A web ACL for the account's public entry points (waf_enabled): the AWS common, known-bad-inputs
# and SQL injection rule groups, and a per-IP rate limit. A CLOUDFRONT web ACL lives in us-east-1,
# as AWS requires, whatever the home Region; the distribution names it in its own settings.

locals {
  waf_managed_groups = [
    { name = "AWSManagedRulesCommonRuleSet", priority = 10, metric = "common" },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 20, metric = "bad-inputs" },
    { name = "AWSManagedRulesSQLiRuleSet", priority = 30, metric = "sqli" },
  ]
}

resource "aws_wafv2_web_acl" "this" {
  # checkov:skip=CKV2_AWS_31:0024 sampled requests and metrics are on; full request logs need an aws-waf-logs- destination the budget approver sizes
  count  = var.waf_enabled ? 1 : 0
  region = local.web_acl_region
  name   = local.web_acl_name
  scope  = var.waf_scope

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.waf_managed_groups

    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.web_acl_name}-${rule.value.metric}"
        sampled_requests_enabled   = true
      }
    }
  }

  rule {
    name     = "rate-limit-per-ip"
    priority = 40

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        evaluation_window_sec = 300
        aggregate_key_type    = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.web_acl_name}-rate"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.web_acl_name
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "this" {
  for_each     = toset(var.waf_enabled && var.waf_scope == "REGIONAL" ? var.waf_resource_arns : [])
  resource_arn = each.value
  web_acl_arn  = aws_wafv2_web_acl.this[0].arn
}
