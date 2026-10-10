# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# CloudWatch alarms that notify an SNS topic, and notify it again when they recover. Lambda errors, throttles
# and p95 duration at 80% of the timeout; HTTP API 5xx and p95 latency. Each alarm is a fixed monthly charge.

locals {
  lambda_dimensions = tomap({ FunctionName = aws_lambda_function.app.function_name })

  alarm_definitions = merge(
    {
      lambda-errors = {
        namespace   = "AWS/Lambda", metric = "Errors", statistic = "Sum", extended = tostring(null)
        dimensions  = local.lambda_dimensions, threshold = 1, periods = 1
        description = "The function returned errors in the last 5 minutes."
      }
      lambda-throttles = {
        namespace   = "AWS/Lambda", metric = "Throttles", statistic = "Sum", extended = tostring(null)
        dimensions  = local.lambda_dimensions, threshold = 1, periods = 1
        description = "Invocations were throttled in the last 5 minutes: concurrency is exhausted."
      }
      lambda-duration-p95 = {
        namespace   = "AWS/Lambda", metric = "Duration", statistic = tostring(null), extended = "p95"
        dimensions  = local.lambda_dimensions, threshold = aws_lambda_function.app.timeout * 1000 * 0.8, periods = 3
        description = "p95 duration has been above 80% of the timeout for 15 minutes."
      }
    },
    {
      api-5xx = {
        namespace   = "AWS/ApiGateway", metric = "5xx", statistic = "Sum", extended = tostring(null)
        dimensions  = tomap({ ApiId = local.overlay.http_api_id, Stage = local.overlay.api_stage }), threshold = 1, periods = 1
        description = "The HTTP API returned 5xx responses in the last 5 minutes."
      }
      api-latency-p95 = {
        namespace   = "AWS/ApiGateway", metric = "Latency", statistic = tostring(null), extended = "p95"
        dimensions  = tomap({ ApiId = local.overlay.http_api_id, Stage = local.overlay.api_stage }), threshold = var.alarm_latency_p95_ms, periods = 3
        description = "HTTP API p95 latency has been above the limit for 15 minutes."
      }
    },
  )
}

resource "aws_cloudwatch_metric_alarm" "alarm" {
  for_each            = local.alarm_definitions
  alarm_name          = "${local.name_prefix}-${each.key}"
  alarm_description   = each.value.description
  namespace           = each.value.namespace
  metric_name         = each.value.metric
  statistic           = each.value.statistic
  extended_statistic  = each.value.extended
  dimensions          = each.value.dimensions
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = each.value.threshold
  period              = 300
  evaluation_periods  = each.value.periods
  datapoints_to_alarm = each.value.periods
  treat_missing_data  = "notBreaching"
  alarm_actions       = [var.alarm_topic_arn]
  ok_actions          = [var.alarm_topic_arn]
}
