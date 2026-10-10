# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# One dashboard, eight widgets, the same layout whatever is switched on. A widget for a switch that
# is off reads a metric nobody publishes, so it shows no data rather than disappearing.

locals {
  waf_metric = {
    REGIONAL   = ["AWS/WAFV2", "BlockedRequests", "WebACL", local.web_acl_name, "Rule", "ALL", "Region", var.region]
    CLOUDFRONT = ["AWS/WAFV2", "BlockedRequests", "WebACL", local.web_acl_name, "Rule", "ALL", { region = "us-east-1" }]
  }

  log_metric_widget = { for k in keys(local.cis_alarms) : k => {
    view    = "timeSeries"
    region  = var.region
    stat    = "Sum"
    period  = 300
    metrics = [[local.metric_namespace, local.cis_alarms[k].metric]]
  } }

  dashboard_widgets = [
    { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = merge(local.log_metric_widget["root-usage"], { title = "Root user activity" }) },
    {
      type = "metric", x = 12, y = 0, width = 12, height = 6
      # The count of refused calls, as the alarm reads it: one sample per matching event.
      properties = merge(local.log_metric_widget["unauthorized-api-calls"], {
        title       = "Unauthorized API calls (alarm at 5 in 5 minutes)"
        stat        = "SampleCount"
        annotations = { horizontal = [{ label = "Alarm", value = 5 }] }
      })
    },
    { type = "metric", x = 0, y = 6, width = 12, height = 6, properties = merge(local.log_metric_widget["iam-policy-changes"], { title = "IAM policy changes" }) },
    { type = "metric", x = 12, y = 6, width = 12, height = 6, properties = merge(local.log_metric_widget["s3-bucket-policy-changes"], { title = "S3 bucket policy changes" }) },
    {
      type = "alarm", x = 0, y = 12, width = 12, height = 6
      properties = {
        title  = "Security alarms"
        alarms = [for n in values(local.alarm_names) : "${local.alarm_arn_prefix}${n}"]
      }
    },
    {
      type = "metric", x = 12, y = 12, width = 12, height = 6
      properties = {
        title   = "CloudTrail events delivered per hour"
        view    = "timeSeries"
        region  = var.region
        stat    = "Sum"
        period  = 3600
        metrics = [["AWS/Logs", "IncomingLogEvents", "LogGroupName", local.log_group_name]]
      }
    },
    {
      type = "log", x = 0, y = 18, width = 12, height = 6
      properties = {
        title  = "Denied calls, last 24 hours"
        region = var.region
        view   = "table"
        query  = "SOURCE '${local.log_group_name}' | filter errorCode like /AccessDenied|UnauthorizedOperation/ | stats count(*) as calls by userIdentity.arn, eventSource, eventName | sort calls desc | limit 20"
      }
    },
    {
      type = "metric", x = 12, y = 18, width = 12, height = 6
      properties = {
        title  = "Findings sent to the alerts topic"
        view   = "timeSeries"
        region = var.region
        stat   = "Sum"
        period = 300
        metrics = [
          ["AWS/Events", "MatchedEvents", "RuleName", "${local.prefix}-guardduty-findings"],
          ["AWS/Events", "MatchedEvents", "RuleName", "${local.prefix}-access-analyzer-findings"],
          ["AWS/Events", "MatchedEvents", "RuleName", "${local.prefix}-securityhub-findings"],
          local.waf_metric[var.waf_scope],
        ]
      }
    },
  ]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = local.dashboard_name

  # The dashboard opens on the last 24 hours, which the denied-calls table names.
  dashboard_body = jsonencode({
    start   = "-PT24H"
    widgets = local.dashboard_widgets
  })
}
