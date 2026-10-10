# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Metric filters on the trail's log group and the alarms that notify the alerts topic.
# The four CIS patterns are copied verbatim from the AWS Security Hub CloudWatch controls, so the
# controls pass; the tests hold a second copy of each string.
# The metrics sit in their own namespace, SecurityBaseline: SecurityBaselineProtect and the
# bootstrap's workload boundary deny cloudwatch:PutMetricData into it. CloudWatch Logs publishes a
# filter's value each time a matching event arrives, and its default value only in a period when
# events arrive but none matches. The single-event alarms read the Maximum of 1 per match, which a
# negative value cannot lower. The refused-calls alarm counts matching events: its filter has no
# default value and the alarm reads the SampleCount. A datapoint written into a metric here, by
# PutMetricData or by a filter on another log group, can raise a Maximum or add a sample, never
# lower either: it can cause a false alarm, never hold a real one down.
# Units. Each filter publishes with unit Count and each of its alarms reads unit Count only. The
# MetricTransformation reference (CloudWatch Logs API) says of a filter's unit: "If you omit this, the
# unit is set as None." The PutMetricAlarm reference says datapoints that name a unit "are aggregated
# separately", and that when a metric has more than one unit and the alarm names none, "the alarm's
# behavior is not defined and it behaves unpredictably". With no unit, a filter on another log group
# that publishes the same metric in, say, Seconds would take these alarms outside the reasoning above.
# With Count on both sides, a datapoint in another unit is aggregated apart and no alarm here reads it;
# one in Count is the case above. The same reference warns that an alarm naming a unit the metric is
# not published in gets no data, so it never fires: the module tests and verify check both say Count.

locals {
  cis_alarms = {
    root-usage = {
      summary   = "The root user made a call (Security Hub control CloudWatch.1)."
      metric    = "RootUsage"
      threshold = 1
      statistic = "Maximum"
      pattern   = "{$.userIdentity.type=\"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType !=\"AwsServiceEvent\"}"
    }
    unauthorized-api-calls = {
      summary   = "Five or more calls were refused within five minutes (CloudWatch.2)."
      metric    = "UnauthorizedApiCalls"
      threshold = 5
      statistic = "SampleCount"
      pattern   = "{($.errorCode=\"*UnauthorizedOperation\") || ($.errorCode=\"AccessDenied*\")}"
    }
    iam-policy-changes = {
      summary   = "An IAM policy was created, changed, attached or detached (CloudWatch.4)."
      metric    = "IamPolicyChanges"
      threshold = 1
      statistic = "Maximum"
      pattern   = "{($.eventSource=iam.amazonaws.com) && (($.eventName=DeleteGroupPolicy) || ($.eventName=DeleteRolePolicy) || ($.eventName=DeleteUserPolicy) || ($.eventName=PutGroupPolicy) || ($.eventName=PutRolePolicy) || ($.eventName=PutUserPolicy) || ($.eventName=CreatePolicy) || ($.eventName=DeletePolicy) || ($.eventName=CreatePolicyVersion) || ($.eventName=DeletePolicyVersion) || ($.eventName=AttachRolePolicy) || ($.eventName=DetachRolePolicy) || ($.eventName=AttachUserPolicy) || ($.eventName=DetachUserPolicy) || ($.eventName=AttachGroupPolicy) || ($.eventName=DetachGroupPolicy))}"
    }
    s3-bucket-policy-changes = {
      summary   = "A bucket policy, ACL, CORS, lifecycle or replication setting changed (CloudWatch.8)."
      metric    = "S3BucketPolicyChanges"
      threshold = 1
      statistic = "Maximum"
      pattern   = "{($.eventSource=s3.amazonaws.com) && (($.eventName=PutBucketAcl) || ($.eventName=PutBucketPolicy) || ($.eventName=PutBucketCors) || ($.eventName=PutBucketLifecycle) || ($.eventName=PutBucketReplication) || ($.eventName=DeleteBucketPolicy) || ($.eventName=DeleteBucketCors) || ($.eventName=DeleteBucketLifecycle) || ($.eventName=DeleteBucketReplication))}"
    }
  }

  # Any use of the break-glass role is worth a message, whoever assumed it.
  log_filters = merge(local.cis_alarms, local.break_glass_on ? {
    break-glass-use = {
      summary   = "BreakGlassAdmin was assumed."
      metric    = "BreakGlassUse"
      threshold = 1
      statistic = "Maximum"
      pattern   = "{($.eventSource=sts.amazonaws.com) && ($.eventName=AssumeRole) && ($.requestParameters.roleArn=\"${local.break_glass_arn}\")}"
    }
  } : {})

  # The refused-calls alarm has its own switch; its filter stays, so the dashboard keeps the metric.
  log_alarms = { for k, a in local.log_filters : k => a if k != "unauthorized-api-calls" || var.unauthorized_api_calls_alarm_enabled }

  metric_namespace = "SecurityBaseline"

  alarm_names = merge(
    { for k in keys(local.log_alarms) : k => "${local.prefix}-${k}" },
    { trail-delivery = "${local.prefix}-trail-delivery" },
  )
}

resource "aws_cloudwatch_log_metric_filter" "this" {
  for_each       = local.log_filters
  name           = "${local.prefix}-${each.key}"
  log_group_name = aws_cloudwatch_log_group.trail.name
  pattern        = each.value.pattern

  # A counted metric takes no default value: SampleCount would count each default 0 as an event.
  metric_transformation {
    name          = each.value.metric
    namespace     = local.metric_namespace
    value         = "1"
    default_value = each.value.statistic == "SampleCount" ? null : "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_metric_alarm" "log" {
  for_each            = local.log_alarms
  alarm_name          = "${local.prefix}-${each.key}"
  alarm_description   = "${each.value.summary} Who and what: dashboard ${local.dashboard_name}."
  namespace           = local.metric_namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  unit                = "Count" # the unit its filter publishes, so datapoints in any other unit are not read
  period              = 300
  evaluation_periods  = 1
  threshold           = each.value.threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]

  # The name comes from the same map as the filter's; the filter is still created first.
  depends_on = [aws_cloudwatch_log_metric_filter.this]
}

# Silence is the failure: no events for two hours means the trail stopped delivering to the log group.
resource "aws_cloudwatch_metric_alarm" "trail_delivery" {
  alarm_name          = local.alarm_names["trail-delivery"]
  alarm_description   = "No CloudTrail events reached ${local.log_group_name} for two hours. Check the trail's delivery status."
  namespace           = "AWS/Logs"
  metric_name         = "IncomingLogEvents"
  dimensions          = { LogGroupName = aws_cloudwatch_log_group.trail.name }
  statistic           = "Sum"
  period              = 3600
  evaluation_periods  = 2
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
