# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
output "alerts_topic_arn" {
  description = "The alerts topic. Workload roots set it as alarm_topic_arn, so every alarm of the account reaches the same people."
  value       = local.topic_arn

  depends_on = [aws_sns_topic_policy.alerts]
}

output "kms_key_arn" {
  description = "The baseline key: trail files, the trail log group and the alerts topic. Null when kms_key_enabled is false."
  value       = local.kms_arn
}

output "trail_arn" {
  description = "The multi-Region trail."
  value       = local.trail_arn

  depends_on = [aws_cloudtrail.this]
}

output "trail_bucket_name" {
  description = "Bucket that holds the trail files (and Config snapshots under config/ when Config is on)."
  value       = aws_s3_bucket.trail.bucket
}

output "trail_log_group_name" {
  description = "Log group that receives the trail's events and feeds the alarms."
  value       = aws_cloudwatch_log_group.trail.name
}

output "dashboard_url" {
  description = "Console address of the security dashboard."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.this.dashboard_name}"
}

output "alarm_names" {
  description = "Alarm key to alarm name."
  value       = local.alarm_names

  depends_on = [aws_cloudwatch_metric_alarm.log, aws_cloudwatch_metric_alarm.trail_delivery]
}

output "metric_filter_patterns" {
  description = "Filter key to the metric filter pattern on the trail log group, for review and for test-metric-filter."
  value       = { for k, a in local.log_filters : k => a.pattern }
}

output "role_arns" {
  description = "People role name to ARN; empty until principals are named."
  value       = { for name, r in aws_iam_role.people : name => r.arn }
}

output "protect_policy_arn" {
  description = "SecurityBaselineProtect, attached to every apply role named and to DeveloperTemplate when it exists."
  value       = aws_iam_policy.protect.arn
}

output "protect_policy_names" {
  description = "The names of the two deny-only policies: <protect_policy_prefix>Protect and <protect_policy_prefix>ProtectWebAcl (the second exists only while the web ACL does)."
  value       = local.protect_policy_names
}

output "waf_web_acl_arn" {
  description = "The web ACL, for a CloudFront distribution's web_acl_id. Null when waf_enabled is off."
  value       = var.waf_enabled ? aws_wafv2_web_acl.this[0].arn : null
}

output "controls" {
  description = "Which controls this account has, one boolean each, so a review reads the choices without the tfvars."
  value       = local.controls
}

output "imds_tokens" {
  description = "The IMDS token mode set for new instances in the home Region: required, or null when imds_v2_required is false."
  value       = try(one(values(aws_ec2_instance_metadata_defaults.this)).http_tokens, null)
}
