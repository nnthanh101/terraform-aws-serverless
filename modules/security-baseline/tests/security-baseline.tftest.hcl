# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests with a mocked provider: no AWS account or credentials are used.
# The account, Region, addresses, principals and IDs are fixtures, not tenant data.
# terraform test

mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_vpcs" {
    defaults = {
      ids = ["vpc-0example00000001"]
    }
  }

  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:aa-example-1:111122223333:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  mock_resource "aws_sns_topic" {
    defaults = {
      arn = "arn:aws:sns:aa-example-1:111122223333:security-baseline-shared-alerts"
    }
  }
}

variables {
  account_id              = "111122223333"
  region                  = "aa-example-1"
  alert_email             = "security@example.com"
  break_glass_external_id = "0f1e2d3c-4b5a-4987-8a6b-5c4d3e2f1a0b"
  ci_apply_role_names     = ["gha-apply-dev", "gha-apply-production"]
}

run "defaults" {
  command = plan

  assert {
    condition     = aws_cloudtrail.this.name == "security-baseline-shared-trail" && aws_cloudtrail.this.s3_bucket_name == "security-baseline-shared-trail-111122223333"
    error_message = "the trail and its bucket follow the naming contract"
  }

  # The bootstrap's workload boundary denies writes to this log group; the role CloudTrail delivers with
  # must never carry it, or sit where the pipeline makes workload roles (pipeline_role_patterns, the
  # idiom of variables.tf l.233-236: the part of each pattern before its first wildcard), or delivery stops.
  assert {
    condition = (
      aws_iam_role.trail_logs.permissions_boundary == null &&
      !anytrue([
        for p in var.pipeline_role_patterns : strcontains(
          "${coalesce(aws_iam_role.trail_logs.path, "/")}${aws_iam_role.trail_logs.name}",
          split("*", p)[0]
        ) if split("*", p)[0] != ""
      ])
    )
    error_message = "the trail's delivery role carries no permissions boundary and matches none of pipeline_role_patterns"
  }
  assert {
    condition     = aws_cloudtrail.this.is_multi_region_trail && aws_cloudtrail.this.include_global_service_events && aws_cloudtrail.this.enable_log_file_validation
    error_message = "the trail covers every Region and global services, with log file validation"
  }
  assert {
    condition     = aws_cloudtrail.this.cloud_watch_logs_group_arn == "arn:aws:logs:aa-example-1:111122223333:log-group:security-baseline-shared-cloudtrail:*" && endswith(aws_cloudtrail.this.cloud_watch_logs_group_arn, ":*")
    error_message = "CloudTrail needs the log group ARN with ':*' appended"
  }
  assert {
    condition     = aws_cloudtrail.this.kms_key_id == aws_kms_key.this[0].arn
    error_message = "trail files are encrypted with the baseline key"
  }
  assert {
    condition     = length(aws_cloudtrail.this.event_selector) == 0 && length(aws_cloudtrail.this.advanced_event_selector) == 0
    error_message = "with no bucket named the trail has no selector, so CloudTrail's default records every management event, read and write, and no data events"
  }
  assert {
    condition     = length(aws_cloudtrail.this.insight_selector) == 0
    error_message = "no CloudTrail Insights"
  }
  assert {
    condition     = aws_kms_key.this[0].enable_key_rotation && aws_kms_key.this[0].rotation_period_in_days == 365 && aws_kms_key.this[0].deletion_window_in_days == 30
    error_message = "the key rotates yearly and waits 30 days before deletion"
  }
  assert {
    condition     = aws_kms_alias.this[0].name == "alias/security-baseline-shared"
    error_message = "the key alias is alias/<prefix>"
  }
  assert {
    condition = (
      length(aws_guardduty_detector.this) + length(aws_securityhub_account.this) + length(aws_config_configuration_recorder.this) +
      length(aws_inspector2_enabler.this) + length(aws_wafv2_web_acl.this) + length(aws_iam_service_linked_role.config) +
      length(aws_iam_policy.protect_web_acl) == 0
    )
    error_message = "no detector, Config recorder, Inspector or web ACL by default: each adds a monthly charge"
  }
  assert {
    condition     = join(",", keys(aws_cloudwatch_event_rule.findings)) == "access-analyzer-findings"
    error_message = "with the detectors off, only the Access Analyzer rule sends findings"
  }
  assert {
    condition     = length(aws_iam_role.people) == 0 && length(aws_iam_role_policy_attachment.break_glass_admin) == 0 && length(aws_iam_role_policy.developer_environments) == 0
    error_message = "no people role exists until someone is named for it"
  }
  assert {
    condition     = join(",", keys(aws_cloudwatch_log_metric_filter.this)) == "iam-policy-changes,root-usage,s3-bucket-policy-changes,unauthorized-api-calls" && join(",", keys(aws_cloudwatch_metric_alarm.log)) == "iam-policy-changes,root-usage,s3-bucket-policy-changes,unauthorized-api-calls"
    error_message = "without a break-glass role there is no break-glass filter or alarm"
  }
  assert {
    condition     = join(",", keys(aws_iam_role_policy_attachment.protect)) == "gha-apply-dev,gha-apply-production"
    error_message = "without DeveloperTemplate, only the apply roles carry the protection policy"
  }
  assert {
    condition     = aws_sns_topic.alerts.name == "security-baseline-shared-alerts" && aws_sns_topic.alerts.kms_master_key_id == aws_kms_key.this[0].arn
    error_message = "the alerts topic is encrypted with the baseline key"
  }
  assert {
    condition     = aws_sns_topic_subscription.email.protocol == "email" && aws_sns_topic_subscription.email.endpoint == "security@example.com"
    error_message = "the alerts topic mails the alert address"
  }
  assert {
    condition     = output.alerts_topic_arn == "arn:aws:sns:aa-example-1:111122223333:security-baseline-shared-alerts"
    error_message = "the topic ARN is built from strings, so it is known at plan"
  }
  assert {
    condition = jsonencode(output.controls) == jsonencode({
      trail             = true, guardduty = false, security_hub = false, config = false, inspector = false, waf = false,
      access_log_bucket = true, unauthorized_api_calls_alarm = true, break_glass_role = false, people_roles = false, access_analyzer = true
    })
    error_message = "the controls output reports the defaults"
  }
  assert {
    condition     = output.dashboard_url == "https://aa-example-1.console.aws.amazon.com/cloudwatch/home?region=aa-example-1#dashboards/dashboard/security-baseline-shared-overview"
    error_message = "the dashboard address names the home Region and the dashboard"
  }
}

run "delivery_role_outside_pipeline_patterns" {
  command = plan

  variables {
    pipeline_role_patterns = ["gha-*", "svc/*"]
  }

  assert {
    condition = (
      aws_iam_role.trail_logs.permissions_boundary == null &&
      !anytrue([
        for p in var.pipeline_role_patterns : strcontains(
          "${coalesce(aws_iam_role.trail_logs.path, "/")}${aws_iam_role.trail_logs.name}",
          split("*", p)[0]
        ) if split("*", p)[0] != ""
      ])
    )
    error_message = "the trail's delivery role carries no permissions boundary and matches none of pipeline_role_patterns"
  }
}

run "no_external_id_needed_without_break_glass" {
  command = plan

  variables {
    break_glass_external_id = null
  }

  assert {
    condition     = length(aws_iam_role.people) == 0
    error_message = "without break-glass users, no external ID is needed"
  }
}

run "key_policy_principals_and_conditions" {
  command = plan

  assert {
    condition = join(",", [for s in jsondecode(aws_kms_key.this[0].policy).Statement : s.Sid]) == join(",", [
      "AccountAdministersKeyThroughIam", "CloudTrailEncryptLogs", "CloudTrailDecryptWithBucketKey", "CloudTrailDescribeKey",
      "CloudWatchLogsUseKey", "CloudWatchAlarmsPublish", "EventBridgePublish", "DenyPipelineRoles",
    ])
    error_message = "the key policy holds each statement exactly once"
  }
  assert {
    condition     = jsondecode(aws_kms_key.this[0].policy).Statement[0].Principal.AWS == "arn:aws:iam::111122223333:root" && jsondecode(aws_kms_key.this[0].policy).Statement[0].Action == "kms:*"
    error_message = "the account administers the key through IAM"
  }
  assert {
    condition = (
      jsondecode(aws_kms_key.this[0].policy).Statement[1].Principal.Service == "cloudtrail.amazonaws.com" &&
      jsondecode(aws_kms_key.this[0].policy).Statement[1].Action == "kms:GenerateDataKey*" &&
      jsondecode(aws_kms_key.this[0].policy).Statement[1].Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:aa-example-1:111122223333:trail/security-baseline-shared-trail" &&
      jsondecode(aws_kms_key.this[0].policy).Statement[1].Condition.StringLike["kms:EncryptionContext:aws:cloudtrail:arn"] == "arn:aws:cloudtrail:*:111122223333:trail/*" &&
      !contains(keys(jsondecode(aws_kms_key.this[0].policy).Statement[1].Condition.StringLike), "kms:EncryptionContext:aws:logs:arn")
    )
    error_message = "CloudTrail encrypts only for this trail, and the encryption context is CloudTrail's, not the Logs one"
  }
  assert {
    condition = alltrue([
      for i in [2, 3] : jsondecode(aws_kms_key.this[0].policy).Statement[i].Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:aa-example-1:111122223333:trail/security-baseline-shared-trail"
    ]) && jsondecode(aws_kms_key.this[0].policy).Statement[2].Action == "kms:Decrypt" && jsondecode(aws_kms_key.this[0].policy).Statement[3].Action == "kms:DescribeKey"
    error_message = "CloudTrail decrypts (bucket key) and describes the key only for this trail"
  }
  assert {
    condition = (
      jsondecode(aws_kms_key.this[0].policy).Statement[4].Principal.Service == "logs.aa-example-1.amazonaws.com" &&
      jsondecode(aws_kms_key.this[0].policy).Statement[4].Condition.ArnEquals["kms:EncryptionContext:aws:logs:arn"] == "arn:aws:logs:aa-example-1:111122223333:log-group:security-baseline-shared-cloudtrail"
    )
    error_message = "CloudWatch Logs uses the key for the trail log group only"
  }
  assert {
    condition = (
      jsondecode(aws_kms_key.this[0].policy).Statement[5].Principal.Service == "cloudwatch.amazonaws.com" &&
      jsondecode(aws_kms_key.this[0].policy).Statement[5].Condition.StringEquals["aws:SourceAccount"] == "111122223333" &&
      jsondecode(aws_kms_key.this[0].policy).Statement[5].Condition.ArnLike["aws:SourceArn"] == "arn:aws:cloudwatch:aa-example-1:111122223333:alarm:*"
    )
    error_message = "any alarm of this account may publish to the encrypted topic, and nothing else through CloudWatch"
  }
  assert {
    condition = (
      jsondecode(aws_kms_key.this[0].policy).Statement[6].Principal.Service == "events.amazonaws.com" &&
      join(",", jsondecode(aws_kms_key.this[0].policy).Statement[6].Action) == "kms:Decrypt,kms:GenerateDataKey*" &&
      !contains(keys(jsondecode(aws_kms_key.this[0].policy).Statement[6]), "Condition")
    )
    error_message = "EventBridge gets the key without source conditions, which KMS does not receive from it; the topic policy names the rules"
  }
  assert {
    condition = (
      jsondecode(aws_kms_key.this[0].policy).Statement[7].Effect == "Deny" &&
      jsondecode(aws_kms_key.this[0].policy).Statement[7].Principal.AWS == "*" &&
      join(",", jsondecode(aws_kms_key.this[0].policy).Statement[7].Condition.ArnLike["aws:PrincipalArn"]) == "arn:aws:iam::111122223333:role/gha-*,arn:aws:iam::111122223333:role/workload/*" &&
      length(setintersection(toset(jsondecode(aws_kms_key.this[0].policy).Statement[7].Action), toset(["kms:Decrypt", "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion", "kms:CreateGrant"]))) == 4
    )
    error_message = "the pipeline and workload roles can neither use nor change the key"
  }
  assert {
    condition = (
      jsondecode(aws_sns_topic_policy.alerts.policy).Statement[1].Sid == "EventBridgePublish" &&
      jsondecode(aws_sns_topic_policy.alerts.policy).Statement[1].Condition.ArnLike["aws:SourceArn"] == "arn:aws:events:aa-example-1:111122223333:rule/security-baseline-shared-*" &&
      jsondecode(aws_sns_topic_policy.alerts.policy).Statement[1].Condition.StringEquals["aws:SourceAccount"] == "111122223333"
    )
    error_message = "the topic accepts only the baseline's own rules"
  }
}

run "trail_bucket_policy_and_lifecycle" {
  command = plan

  assert {
    condition     = join(",", [for s in jsondecode(aws_s3_bucket_policy.trail.policy).Statement : s.Sid]) == "DenyInsecureTransport,DenyOldTls,CloudTrailAclCheck,CloudTrailWrite,DenyChangesByPipelineRoles"
    error_message = "the trail bucket policy holds exactly these statements"
  }
  assert {
    condition = (
      jsondecode(aws_s3_bucket_policy.trail.policy).Statement[2].Action == "s3:GetBucketAcl" &&
      jsondecode(aws_s3_bucket_policy.trail.policy).Statement[2].Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:aa-example-1:111122223333:trail/security-baseline-shared-trail"
    )
    error_message = "only this trail checks the bucket ACL"
  }
  assert {
    condition = (
      jsondecode(aws_s3_bucket_policy.trail.policy).Statement[3].Resource == "arn:aws:s3:::security-baseline-shared-trail-111122223333/AWSLogs/111122223333/*" &&
      jsondecode(aws_s3_bucket_policy.trail.policy).Statement[3].Condition.StringEquals["s3:x-amz-acl"] == "bucket-owner-full-control" &&
      jsondecode(aws_s3_bucket_policy.trail.policy).Statement[3].Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:aa-example-1:111122223333:trail/security-baseline-shared-trail"
    )
    error_message = "only this trail writes, only under AWSLogs/<account>/, with bucket-owner-full-control"
  }
  assert {
    condition = (
      jsondecode(aws_s3_bucket_policy.trail.policy).Statement[4].Effect == "Deny" &&
      length(setintersection(toset(jsondecode(aws_s3_bucket_policy.trail.policy).Statement[4].Action), toset(["s3:PutBucket*", "s3:DeleteObject*", "s3:PutObject", "s3:BypassGovernanceRetention"]))) == 4 &&
      join(",", jsondecode(aws_s3_bucket_policy.trail.policy).Statement[4].Condition.ArnLike["aws:PrincipalArn"]) == "arn:aws:iam::111122223333:role/gha-*,arn:aws:iam::111122223333:role/workload/*"
    )
    error_message = "the pipeline and workload roles can neither change the bucket nor write or delete its files"
  }
  assert {
    condition = (
      length(aws_s3_bucket_lifecycle_configuration.trail.rule) == 1 &&
      aws_s3_bucket_lifecycle_configuration.trail.rule[0].expiration[0].days == 400 &&
      aws_s3_bucket_lifecycle_configuration.trail.rule[0].noncurrent_version_expiration[0].noncurrent_days == 90 &&
      aws_s3_bucket_lifecycle_configuration.trail.rule[0].abort_incomplete_multipart_upload[0].days_after_initiation == 7 &&
      length(aws_s3_bucket_lifecycle_configuration.trail.rule[0].transition) == 0
    )
    error_message = "trail files expire after 400 days, with no Glacier transition"
  }
  assert {
    condition = (
      [for r in aws_s3_bucket_server_side_encryption_configuration.trail.rule : "${r.bucket_key_enabled}/${r.apply_server_side_encryption_by_default[0].sse_algorithm}/${r.apply_server_side_encryption_by_default[0].kms_master_key_id}"] ==
      ["true/aws:kms/arn:aws:kms:aa-example-1:111122223333:key/00000000-0000-0000-0000-000000000000"]
    )
    error_message = "the trail bucket uses SSE-KMS with the baseline key and a bucket key"
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.trail.block_public_policy && aws_s3_bucket_public_access_block.trail.restrict_public_buckets && aws_s3_bucket_ownership_controls.trail.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "the trail bucket is private and ignores ACLs"
  }
  assert {
    condition     = aws_s3_bucket_logging.trail[0].target_prefix == "trail/" && aws_s3_bucket.access_logs[0].bucket == "security-baseline-shared-access-logs-111122223333"
    error_message = "reads of the trail bucket are logged to the access-log bucket under trail/"
  }
  assert {
    condition = (
      join(",", [for s in jsondecode(aws_s3_bucket_policy.access_logs[0].policy).Statement : s.Sid]) == "DenyInsecureTransport,DenyOldTls,S3ServerAccessLogs,DenyChangesByPipelineRoles" &&
      jsondecode(aws_s3_bucket_policy.access_logs[0].policy).Statement[2].Principal.Service == "logging.s3.amazonaws.com" &&
      jsondecode(aws_s3_bucket_policy.access_logs[0].policy).Statement[2].Resource == "arn:aws:s3:::security-baseline-shared-access-logs-111122223333/trail/*" &&
      jsondecode(aws_s3_bucket_policy.access_logs[0].policy).Statement[2].Condition.ArnLike["aws:SourceArn"] == "arn:aws:s3:::security-baseline-shared-trail-111122223333" &&
      jsondecode(aws_s3_bucket_policy.access_logs[0].policy).Statement[2].Condition.StringEquals["aws:SourceAccount"] == "111122223333"
    )
    error_message = "S3 delivers only the trail bucket's access logs, only under trail/"
  }
  assert {
    condition     = [for r in aws_s3_bucket_server_side_encryption_configuration.access_logs[0].rule : r.apply_server_side_encryption_by_default[0].sse_algorithm] == ["AES256"] && aws_s3_bucket_lifecycle_configuration.access_logs[0].rule[0].expiration[0].days == 400
    error_message = "S3 delivers server access logs only to SSE-S3 buckets; they expire with the trail files"
  }
  assert {
    condition = (
      aws_s3_bucket_public_access_block.access_logs[0].block_public_acls && aws_s3_bucket_public_access_block.access_logs[0].block_public_policy &&
      aws_s3_bucket_public_access_block.access_logs[0].ignore_public_acls && aws_s3_bucket_public_access_block.access_logs[0].restrict_public_buckets &&
      aws_s3_bucket_versioning.access_logs[0].versioning_configuration[0].status == "Enabled"
    )
    error_message = "the access-log bucket is private and versioned"
  }
  assert {
    condition     = aws_cloudwatch_log_group.trail.retention_in_days == 400 && aws_cloudwatch_log_group.trail.kms_key_id == aws_kms_key.this[0].arn
    error_message = "the trail log group keeps the same 400 days and is encrypted with the baseline key"
  }
  assert {
    condition = (
      jsondecode(aws_iam_role.trail_logs.assume_role_policy).Statement[0].Condition.StringEquals["aws:SourceArn"] == "arn:aws:cloudtrail:aa-example-1:111122223333:trail/security-baseline-shared-trail" &&
      jsondecode(aws_iam_role_policy.trail_logs.policy).Statement[0].Resource == "arn:aws:logs:aa-example-1:111122223333:log-group:security-baseline-shared-cloudtrail:log-stream:111122223333_CloudTrail_*"
    )
    error_message = "the delivery role serves this trail only and writes only its streams"
  }
}

run "no_access_log_bucket_when_off" {
  command = plan

  variables {
    access_log_bucket_enabled = false
  }

  assert {
    condition     = length(aws_s3_bucket.access_logs) == 0 && length(aws_s3_bucket_logging.trail) == 0 && !contains(flatten([for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Resource if s.Sid == "ProtectLogBuckets"]), "arn:aws:s3:::security-baseline-shared-access-logs-111122223333")
    error_message = "with the access-log bucket off, nothing logs to it and the protection policy does not name it"
  }
}

run "cis_filters_are_verbatim" {
  command = plan

  # A second copy of the AWS Security Hub CloudWatch.1, .2, .4 and .8 patterns.
  assert {
    condition     = aws_cloudwatch_log_metric_filter.this["root-usage"].pattern == "{$.userIdentity.type=\"Root\" && $.userIdentity.invokedBy NOT EXISTS && $.eventType !=\"AwsServiceEvent\"}"
    error_message = "CloudWatch.1 pattern differs from AWS's"
  }
  assert {
    condition     = aws_cloudwatch_log_metric_filter.this["unauthorized-api-calls"].pattern == "{($.errorCode=\"*UnauthorizedOperation\") || ($.errorCode=\"AccessDenied*\")}"
    error_message = "CloudWatch.2 pattern differs from AWS's"
  }
  assert {
    condition     = aws_cloudwatch_log_metric_filter.this["iam-policy-changes"].pattern == "{($.eventSource=iam.amazonaws.com) && (($.eventName=DeleteGroupPolicy) || ($.eventName=DeleteRolePolicy) || ($.eventName=DeleteUserPolicy) || ($.eventName=PutGroupPolicy) || ($.eventName=PutRolePolicy) || ($.eventName=PutUserPolicy) || ($.eventName=CreatePolicy) || ($.eventName=DeletePolicy) || ($.eventName=CreatePolicyVersion) || ($.eventName=DeletePolicyVersion) || ($.eventName=AttachRolePolicy) || ($.eventName=DetachRolePolicy) || ($.eventName=AttachUserPolicy) || ($.eventName=DetachUserPolicy) || ($.eventName=AttachGroupPolicy) || ($.eventName=DetachGroupPolicy))}"
    error_message = "CloudWatch.4 pattern differs from AWS's"
  }
  assert {
    condition     = aws_cloudwatch_log_metric_filter.this["s3-bucket-policy-changes"].pattern == "{($.eventSource=s3.amazonaws.com) && (($.eventName=PutBucketAcl) || ($.eventName=PutBucketPolicy) || ($.eventName=PutBucketCors) || ($.eventName=PutBucketLifecycle) || ($.eventName=PutBucketReplication) || ($.eventName=DeleteBucketPolicy) || ($.eventName=DeleteBucketCors) || ($.eventName=DeleteBucketLifecycle) || ($.eventName=DeleteBucketReplication))}"
    error_message = "CloudWatch.8 pattern differs from AWS's"
  }
  assert {
    condition = length(aws_cloudwatch_log_metric_filter.this) == 4 && alltrue([
      for f in aws_cloudwatch_log_metric_filter.this : f.log_group_name == "security-baseline-shared-cloudtrail" && f.metric_transformation[0].namespace == "SecurityBaseline" && f.metric_transformation[0].value == "1"
    ])
    error_message = "four filters on the trail log group, each counting 1 per match into the baseline's own namespace, SecurityBaseline"
  }
  assert {
    condition = length(aws_cloudwatch_log_metric_filter.this) == 4 && alltrue([
      for f in aws_cloudwatch_log_metric_filter.this : f.metric_transformation[0].unit == "Count"
    ])
    error_message = "each of the four filters publishes with unit Count, so a filter elsewhere that publishes the metric in another unit is aggregated apart"
  }
  assert {
    condition = alltrue([
      for k, f in aws_cloudwatch_log_metric_filter.this : k == "unauthorized-api-calls" ? f.metric_transformation[0].default_value == null : f.metric_transformation[0].default_value == "0"
    ])
    error_message = "the refused-calls filter has no default value, which its alarm's SampleCount would count as a refused call; the others default to 0"
  }
  assert {
    condition     = join(",", [for k, f in aws_cloudwatch_log_metric_filter.this : "${k}=${f.metric_transformation[0].name}"]) == "iam-policy-changes=IamPolicyChanges,root-usage=RootUsage,s3-bucket-policy-changes=S3BucketPolicyChanges,unauthorized-api-calls=UnauthorizedApiCalls"
    error_message = "metric names follow the naming contract"
  }
}

run "alarm_thresholds" {
  command = plan

  variables {
    break_glass_principal_arns = ["arn:aws:iam::111122223333:user/example-break-glass"]
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.log["unauthorized-api-calls"].statistic == "SampleCount" && aws_cloudwatch_metric_alarm.log["unauthorized-api-calls"].threshold == 5 && aws_cloudwatch_metric_alarm.log["unauthorized-api-calls"].period == 300
    error_message = "unauthorized calls alarm at 5 refused calls in 5 minutes, counted as samples so a written value cannot lower the count"
  }
  assert {
    condition = length(aws_cloudwatch_metric_alarm.log) == 5 && alltrue([
      for k, a in aws_cloudwatch_metric_alarm.log : a.threshold == (k == "unauthorized-api-calls" ? 5 : 1) &&
      a.namespace == "SecurityBaseline" && a.statistic == (k == "unauthorized-api-calls" ? "SampleCount" : "Maximum") && a.period == 300 && a.evaluation_periods == 1 &&
      a.comparison_operator == "GreaterThanOrEqualToThreshold" && a.treat_missing_data == "notBreaching" &&
      a.alarm_actions == toset(["arn:aws:sns:aa-example-1:111122223333:security-baseline-shared-alerts"]) && try(length(a.ok_actions), 0) == 0
    ])
    error_message = "every other log alarm fires on a single match, read as the Maximum so a negative value written into the metric cannot hide it, notifies only the alerts topic, and treats silence as fine"
  }
  assert {
    condition = length(aws_cloudwatch_log_metric_filter.this) == 5 && alltrue([
      for f in aws_cloudwatch_log_metric_filter.this : f.metric_transformation[0].unit == "Count"
    ])
    error_message = "all five filters, the break-glass one too, publish with unit Count"
  }
  assert {
    condition = length(aws_cloudwatch_metric_alarm.log) == 5 && alltrue([
      for k, a in aws_cloudwatch_metric_alarm.log : a.unit == "Count" && a.unit == aws_cloudwatch_log_metric_filter.this[k].metric_transformation[0].unit
    ])
    error_message = "every log alarm reads unit Count, the unit its filter publishes: datapoints in any other unit are not read, and the alarm cannot wait on a unit nothing publishes"
  }
  assert {
    condition     = strcontains(aws_cloudwatch_log_metric_filter.this["break-glass-use"].pattern, "($.requestParameters.roleArn=\"arn:aws:iam::111122223333:role/BreakGlassAdmin\")") && aws_cloudwatch_log_metric_filter.this["break-glass-use"].metric_transformation[0].name == "BreakGlassUse"
    error_message = "once the break-glass role exists, its alarm watches the BreakGlassAdmin role ARN"
  }
  assert {
    condition = (
      aws_cloudwatch_metric_alarm.trail_delivery.namespace == "AWS/Logs" && aws_cloudwatch_metric_alarm.trail_delivery.metric_name == "IncomingLogEvents" &&
      aws_cloudwatch_metric_alarm.trail_delivery.dimensions["LogGroupName"] == "security-baseline-shared-cloudtrail" &&
      aws_cloudwatch_metric_alarm.trail_delivery.comparison_operator == "LessThanThreshold" && aws_cloudwatch_metric_alarm.trail_delivery.threshold == 1 &&
      aws_cloudwatch_metric_alarm.trail_delivery.period == 3600 && aws_cloudwatch_metric_alarm.trail_delivery.evaluation_periods == 2 &&
      aws_cloudwatch_metric_alarm.trail_delivery.datapoints_to_alarm == 2 && aws_cloudwatch_metric_alarm.trail_delivery.treat_missing_data == "breaching"
    )
    error_message = "two silent hours on the trail log group raise the delivery alarm"
  }
  assert {
    condition = jsonencode(output.alarm_names) == jsonencode({
      root-usage               = "security-baseline-shared-root-usage"
      unauthorized-api-calls   = "security-baseline-shared-unauthorized-api-calls"
      iam-policy-changes       = "security-baseline-shared-iam-policy-changes"
      s3-bucket-policy-changes = "security-baseline-shared-s3-bucket-policy-changes"
      break-glass-use          = "security-baseline-shared-break-glass-use"
      trail-delivery           = "security-baseline-shared-trail-delivery"
    })
    error_message = "six alarms with a break-glass role, named <prefix>-<key>"
  }
}

run "unauthorized_calls_alarm_switched_off" {
  command = plan

  variables {
    unauthorized_api_calls_alarm_enabled = false
  }

  assert {
    condition     = !contains(keys(aws_cloudwatch_metric_alarm.log), "unauthorized-api-calls") && length(aws_cloudwatch_metric_alarm.log) == 3
    error_message = "the refused-calls alarm can be switched off on its own"
  }
  assert {
    condition     = contains(keys(aws_cloudwatch_log_metric_filter.this), "unauthorized-api-calls")
    error_message = "its filter stays, so the metric keeps its data"
  }
  assert {
    condition = (
      length(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets) == 8 &&
      jsonencode(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets[1].properties.metrics) == jsonencode([["SecurityBaseline", "UnauthorizedApiCalls"]]) &&
      !contains(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets[4].properties.alarms, "arn:aws:cloudwatch:aa-example-1:111122223333:alarm:security-baseline-shared-unauthorized-api-calls")
    )
    error_message = "the dashboard keeps the refused-calls widget, and the alarm widget lists only alarms that exist"
  }
}

run "dashboard_has_eight_widgets" {
  command = plan

  assert {
    condition     = aws_cloudwatch_dashboard.this.dashboard_name == "security-baseline-shared-overview" && length(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets) == 8
    error_message = "one dashboard with eight widgets"
  }
  assert {
    condition = join("|", [for w in jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets : w.properties.title]) == join("|", [
      "Root user activity", "Unauthorized API calls (alarm at 5 in 5 minutes)", "IAM policy changes", "S3 bucket policy changes",
      "Security alarms", "CloudTrail events delivered per hour", "Denied calls, last 24 hours", "Findings sent to the alerts topic",
    ])
    error_message = "the widgets and their order are fixed"
  }
  assert {
    condition     = jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets[1].properties.annotations.horizontal[0].value == 5
    error_message = "the unauthorized-calls widget marks the alarm threshold"
  }
  assert {
    condition     = join(",", [for w in slice(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets, 0, 4) : w.properties.stat]) == "Sum,SampleCount,Sum,Sum"
    error_message = "the unauthorized-calls widget reads the SampleCount its alarm reads; the other activity widgets sum their matches"
  }
  assert {
    condition = jsonencode([for w in slice(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets, 0, 4) : w.properties.metrics]) == jsonencode([
      [["SecurityBaseline", "RootUsage"]], [["SecurityBaseline", "UnauthorizedApiCalls"]],
      [["SecurityBaseline", "IamPolicyChanges"]], [["SecurityBaseline", "S3BucketPolicyChanges"]],
    ])
    error_message = "the four activity widgets read the metrics the alarms read, in the SecurityBaseline namespace"
  }
  assert {
    condition     = length(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets[4].properties.alarms) == 5 && contains(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets[4].properties.alarms, "arn:aws:cloudwatch:aa-example-1:111122223333:alarm:security-baseline-shared-trail-delivery")
    error_message = "the alarm widget lists every baseline alarm"
  }
  assert {
    condition     = startswith(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets[6].properties.query, "SOURCE 'security-baseline-shared-cloudtrail' | filter errorCode like /AccessDenied|UnauthorizedOperation/")
    error_message = "the denied-calls table reads the trail log group"
  }
  assert {
    condition     = jsonencode(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets[7].properties.metrics[3]) == jsonencode(["AWS/WAFV2", "BlockedRequests", "WebACL", "security-baseline-shared-web", "Rule", "ALL", "Region", "aa-example-1"])
    error_message = "a regional web ACL's blocked requests carry the Region dimension"
  }
}

run "dashboard_same_with_every_option_on" {
  command = plan

  variables {
    guardduty_enabled          = true
    config_enabled             = true
    security_hub_enabled       = true
    inspector_enabled          = true
    waf_enabled                = true
    waf_scope                  = "CLOUDFRONT"
    s3_data_event_bucket_names = ["example-app-files"]
    break_glass_principal_arns = ["arn:aws:iam::111122223333:user/example-break-glass"]
    trusted_principal_arns     = ["arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_SecurityAudit_*"]
  }

  assert {
    condition = join("|", [for w in jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets : w.properties.title]) == join("|", [
      "Root user activity", "Unauthorized API calls (alarm at 5 in 5 minutes)", "IAM policy changes", "S3 bucket policy changes",
      "Security alarms", "CloudTrail events delivered per hour", "Denied calls, last 24 hours", "Findings sent to the alerts topic",
    ])
    error_message = "switching options on changes no widget"
  }
  assert {
    condition     = jsonencode(jsondecode(aws_cloudwatch_dashboard.this.dashboard_body).widgets[7].properties.metrics[3]) == jsonencode(["AWS/WAFV2", "BlockedRequests", "WebACL", "security-baseline-shared-web", "Rule", "ALL", { region = "us-east-1" }])
    error_message = "a CloudFront web ACL's metrics are read in us-east-1, without a Region dimension"
  }
}

run "role_trusts" {
  command = plan

  variables {
    break_glass_principal_arns = ["arn:aws:iam::111122223333:user/example-break-glass"]
    trusted_principal_arns     = ["arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_SecurityAudit_*"]
  }

  assert {
    condition     = join(",", keys(aws_iam_role.people)) == "BreakGlassAdmin,DeveloperTemplate,SecurityAuditor"
    error_message = "three people roles once principals are named"
  }
  assert {
    condition     = alltrue([for r in aws_iam_role.people : r.path == "/" && r.max_session_duration == 3600])
    error_message = "every people role sits at path / and lasts at most an hour"
  }
  assert {
    condition = (
      jsondecode(aws_iam_role.people["BreakGlassAdmin"].assume_role_policy).Statement[0].Principal.AWS == ["arn:aws:iam::111122223333:user/example-break-glass"] &&
      join(",", keys(jsondecode(aws_iam_role.people["BreakGlassAdmin"].assume_role_policy).Statement[0].Condition)) == "Bool,NumericLessThan,StringEquals" &&
      jsondecode(aws_iam_role.people["BreakGlassAdmin"].assume_role_policy).Statement[0].Condition.StringEquals["sts:ExternalId"] == var.break_glass_external_id &&
      jsondecode(aws_iam_role.people["BreakGlassAdmin"].assume_role_policy).Statement[0].Condition.Bool["aws:MultiFactorAuthPresent"] == "true" &&
      jsondecode(aws_iam_role.people["BreakGlassAdmin"].assume_role_policy).Statement[0].Condition.NumericLessThan["aws:MultiFactorAuthAge"] == 3600
    )
    error_message = "BreakGlassAdmin trusts only the named users, with the external ID and an MFA sign-in within the hour"
  }
  assert {
    condition     = aws_iam_role_policy_attachment.break_glass_admin[0].policy_arn == "arn:aws:iam::aws:policy/AdministratorAccess"
    error_message = "BreakGlassAdmin is the administrator for emergencies"
  }
  assert {
    condition = (
      join(",", sort([for a in aws_iam_role_policy_attachment.people : a.policy_arn if a.role == "SecurityAuditor"])) == "arn:aws:iam::aws:policy/SecurityAudit,arn:aws:iam::aws:policy/job-function/ViewOnlyAccess" &&
      join(",", [for a in aws_iam_role_policy_attachment.people : a.policy_arn if a.role == "DeveloperTemplate"]) == "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
    )
    error_message = "each role carries only its AWS managed policies"
  }
  assert {
    condition = (
      length(jsondecode(aws_iam_role_policy.developer_environments[0].policy).Statement) > 0 &&
      alltrue([for s in jsondecode(aws_iam_role_policy.developer_environments[0].policy).Statement : s.Effect == "Deny" || !anytrue([for a in flatten([s.Action]) : startswith(a, "iam:")])]) &&
      aws_iam_role.people["DeveloperTemplate"].permissions_boundary == null
    )
    error_message = "DeveloperTemplate has no IAM rights, so it needs no boundary"
  }
  assert {
    condition = (
      jsondecode(aws_iam_role_policy.developer_environments[0].policy).Statement[3].Sid == "DenyProductionData" &&
      jsondecode(aws_iam_role_policy.developer_environments[0].policy).Statement[3].Effect == "Deny" &&
      jsondecode(aws_iam_role_policy.developer_environments[0].policy).Statement[3].Condition.StringEquals["aws:ResourceTag/environment"] == ["production"] &&
      contains(jsondecode(aws_iam_role_policy.developer_environments[0].policy).Statement[3].Action, "lambda:InvokeFunction")
    )
    error_message = "resources tagged production stay out of DeveloperTemplate's reach"
  }
  assert {
    condition     = contains(jsondecode(aws_iam_role_policy.developer_environments[0].policy).Statement[0].Resource, "arn:aws:logs:aa-example-1:111122223333:log-group:*-dev-*") && jsondecode(aws_iam_role_policy.developer_environments[0].policy).Statement[1].Resource == ["arn:aws:lambda:aa-example-1:111122223333:function:*-dev-*"]
    error_message = "DeveloperTemplate reads logs and invokes functions of the developer environments only"
  }
  assert {
    condition = (
      jsondecode(aws_iam_role_policy.auditor_read_trail[0].policy).Statement[2].Condition.StringEquals["kms:ViaService"] == ["s3.aa-example-1.amazonaws.com", "logs.aa-example-1.amazonaws.com"] &&
      jsondecode(aws_iam_role_policy.auditor_read_trail[0].policy).Statement[0].Resource == "arn:aws:s3:::security-baseline-shared-trail-111122223333/*"
    )
    error_message = "SecurityAuditor reads trail files and decrypts only through S3 and CloudWatch Logs"
  }
  assert {
    condition = (
      jsondecode(aws_iam_role_policy.auditor_read_trail[0].policy).Statement[3].Resource == ["arn:aws:logs:aa-example-1:111122223333:log-group:security-baseline-shared-cloudtrail", "arn:aws:logs:aa-example-1:111122223333:log-group:security-baseline-shared-cloudtrail:*"] &&
      contains(jsondecode(aws_iam_role_policy.auditor_read_trail[0].policy).Statement[3].Action, "logs:GetQueryResults") &&
      alltrue([for s in concat(jsondecode(aws_iam_role_policy.auditor_read_trail[0].policy).Statement, jsondecode(aws_iam_role_policy.developer_environments[0].policy).Statement) : s.Resource != "*" || s.Effect == "Deny" || s.Sid == "TracesAndMetrics"])
    )
    error_message = "log queries and their results are scoped to log groups; only trace and metric reads use *"
  }
  assert {
    condition     = join(",", keys(aws_iam_role_policy_attachment.protect)) == "DeveloperTemplate,gha-apply-dev,gha-apply-production"
    error_message = "DeveloperTemplate carries the protection policy once it exists"
  }
  assert {
    condition     = contains(keys(aws_cloudwatch_metric_alarm.log), "break-glass-use")
    error_message = "the break-glass alarm comes with the break-glass role"
  }
}

# Without a break-glass user, so no sensitive external ID sits in the roles these assertions read.
run "people_trusts" {
  command = plan

  variables {
    trusted_principal_arns = [
      "arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_SecurityAudit_*",
      "arn:aws:iam::111122223333:user/example-auditor",
    ]
  }

  # Each role's trust by a literal key: a failing assertion then prints two strings, not the whole role map.
  assert {
    condition = alltrue([
      for t in [aws_iam_role.people["SecurityAuditor"].assume_role_policy, aws_iam_role.people["DeveloperTemplate"].assume_role_policy] :
      join(",", [for s in jsondecode(t).Statement : s.Sid]) == "NamedUsersWithRecentMfa,NamedRoles" &&
      alltrue([for s in jsondecode(t).Statement : s.Effect == "Allow" && s.Principal.AWS == "arn:aws:iam::111122223333:root" && s.Action == "sts:AssumeRole"])
    ])
    error_message = "the auditor and developer roles trust the account, in one statement for the users named and one for the roles named"
  }
  assert {
    condition = alltrue([
      for t in [aws_iam_role.people["SecurityAuditor"].assume_role_policy, aws_iam_role.people["DeveloperTemplate"].assume_role_policy] :
      jsonencode(jsondecode(t).Statement[0].Condition) == jsonencode({
        ArnLike         = { "aws:PrincipalArn" = ["arn:aws:iam::111122223333:user/example-auditor"] }
        Bool            = { "aws:MultiFactorAuthPresent" = "true" }
        NumericLessThan = { "aws:MultiFactorAuthAge" = 3600 }
      })
    ])
    error_message = "an IAM user named passes only with an MFA sign-in within the hour: Bool, so a call with long-term access keys, which carries no MFA key, is refused"
  }
  assert {
    condition = alltrue([
      for t in [aws_iam_role.people["SecurityAuditor"].assume_role_policy, aws_iam_role.people["DeveloperTemplate"].assume_role_policy] :
      jsonencode(jsondecode(t).Statement[1].Condition) == jsonencode({
        ArnLike = { "aws:PrincipalArn" = ["arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_SecurityAudit_*"] }
      })
    ])
    error_message = "the roles named (Identity Center by pattern) pass by ARN alone: their sessions carry no MFA key"
  }
  assert {
    condition = alltrue([
      for t in [aws_iam_role.people["SecurityAuditor"].assume_role_policy, aws_iam_role.people["DeveloperTemplate"].assume_role_policy] : alltrue([
        for s in jsondecode(t).Statement :
        !contains(keys(s.Condition), "BoolIfExists") && (
          !anytrue([for a in s.Condition.ArnLike["aws:PrincipalArn"] : strcontains(a, ":user/")]) ||
          try(s.Condition.Bool["aws:MultiFactorAuthPresent"], "") == "true"
        )
      ])
    ])
    error_message = "no statement lets an IAM user in without MFA: none uses BoolIfExists, and every one that names a user requires MFA"
  }
}

run "trust_with_roles_only" {
  command = plan

  variables {
    trusted_principal_arns = ["arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/ap-southeast-2/AWSReservedSSO_Developer_0123456789abcdef"]
  }

  assert {
    condition     = join(",", [for s in jsondecode(aws_iam_role.people["SecurityAuditor"].assume_role_policy).Statement : s.Sid]) == "NamedRoles"
    error_message = "with no IAM user named there is no user statement, and no condition list is left empty"
  }
}

run "trust_with_users_only" {
  command = plan

  variables {
    trusted_principal_arns = ["arn:aws:iam::111122223333:user/example-auditor"]
  }

  assert {
    condition = (
      join(",", [for s in jsondecode(aws_iam_role.people["DeveloperTemplate"].assume_role_policy).Statement : s.Sid]) == "NamedUsersWithRecentMfa" &&
      jsondecode(aws_iam_role.people["DeveloperTemplate"].assume_role_policy).Statement[0].Condition.Bool["aws:MultiFactorAuthPresent"] == "true"
    )
    error_message = "with only IAM users named, the only way in is with MFA"
  }
}

run "protect_policy" {
  command = plan

  assert {
    condition = join(",", [for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Sid]) == join(",", [
      "ProtectTrail", "ProtectTrailLogGroup", "ProtectAlarmsAndDashboard", "ProtectBaselineMetrics", "ProtectAlertsTopic",
      "ProtectBaselineKey", "ProtectLogBuckets", "ProtectAccountSettings", "ProtectDefaultVpc", "ProtectDetectors",
      "ProtectRuleAndWebAcl", "DenyAssumingPeopleRoles", "ProtectBaselineIam",
    ])
    error_message = "the protection policy holds each statement exactly once"
  }
  assert {
    condition     = length(jsondecode(aws_iam_policy.protect.policy).Statement) > 0 && alltrue([for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Effect == "Deny"])
    error_message = "the protection policy only denies"
  }
  assert {
    condition     = length(aws_iam_policy.protect.policy) <= 6144
    error_message = "the protection policy fits IAM's 6,144-character managed policy limit"
  }
  # The trail log group: a deny of every logs action but the reads, with no condition to narrow it.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
      if s.Sid == "ProtectTrailLogGroup" && s.Effect == "Deny" && !contains(keys(s), "Action") && !contains(keys(s), "Condition") &&
      toset(try(s.NotAction, [])) == toset([
        "logs:Get*", "logs:Describe*", "logs:List*", "logs:FilterLogEvents", "logs:StartQuery", "logs:StopQuery",
        "logs:GetQueryResults", "logs:StartLiveTail", "logs:StopLiveTail",
      ]) &&
      s.Resource == ["arn:aws:logs:aa-example-1:111122223333:log-group:security-baseline-shared-cloudtrail", "arn:aws:logs:aa-example-1:111122223333:log-group:security-baseline-shared-cloudtrail:*"]
    ]) == 1
    error_message = "the apply roles keep only reading and querying the trail log group's events"
  }
  # Each write that could hide, reshape, copy out or add to the trail's events matches no kept read, so it is denied.
  # logs:PutIndexPolicy is not in this list: IAM gives it no resource type, so no log-group deny ever
  # reaches it, and asserting it here proved only that its name matches none of the kept reads.
  assert {
    condition = alltrue([
      for a in [
        "logs:PutLogEvents", "logs:CreateLogStream", "logs:PutSubscriptionFilter", "logs:CreateExportTask", "logs:UntagResource",
        "logs:UntagLogGroup", "logs:TagResource", "logs:PutLogGroupDeletionProtection", "logs:PutBearerTokenAuthentication",
        "logs:PutRetentionPolicy", "logs:PutMetricFilter", "logs:DeleteMetricFilter", "logs:DeleteLogGroup",
        "logs:AssociateKmsKey", "logs:DisassociateKmsKey", "logs:PutDataProtectionPolicy", "logs:PutTransformer",
        "logs:ProcessWithPipeline", "logs:Unmask",
        ] : !anytrue([
          for p in flatten([for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.NotAction if s.Sid == "ProtectTrailLogGroup"]) :
          can(regex("^${replace(p, "*", ".*")}$", a))
      ])
    ])
    error_message = "no write on the trail log group falls under the reads the apply roles keep"
  }
  # Account-level logs policies apply to the trail log group without naming it, so they are denied everywhere.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
      if s.Effect == "Deny" && s.Resource == "*" && !contains(keys(s), "Condition") &&
      length(setsubtract(toset(["logs:PutAccountPolicy", "logs:DeleteAccountPolicy"]), toset(flatten([try(s.Action, [])])))) == 0
    ]) == 1
    error_message = "the apply roles can neither set nor remove an account-level logs policy"
  }
  assert {
    condition     = aws_iam_policy.protect.name == "SecurityBaselineProtect" && aws_iam_policy.protect.path == "/security-baseline/"
    error_message = "the policy name and path follow the naming contract"
  }
  assert {
    condition = (
      length(setintersection(toset([for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Action if s.Sid == "ProtectBaselineKey"][0]), toset(["kms:ScheduleKeyDeletion", "kms:Disable*", "kms:PutKeyPolicy", "kms:*Grant", "kms:Decrypt"]))) == 5 &&
      [for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Resource if s.Sid == "ProtectBaselineKey"][0] == ["arn:aws:kms:aa-example-1:111122223333:key/00000000-0000-0000-0000-000000000000", "arn:aws:kms:aa-example-1:111122223333:alias/security-baseline-shared"]
    )
    error_message = "the apply roles can neither use, disable, re-grant nor delete the baseline key"
  }
  assert {
    condition     = jsondecode(aws_iam_policy.protect.policy).Statement[0].Resource == "arn:aws:cloudtrail:aa-example-1:111122223333:trail/security-baseline-shared-trail" && contains(jsondecode(aws_iam_policy.protect.policy).Statement[0].Action, "cloudtrail:Stop*")
    error_message = "the apply roles cannot stop or change the trail"
  }
  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
      if s.Sid == "ProtectBaselineMetrics" && s.Action == "cloudwatch:PutMetricData" && s.Resource == "*" &&
      jsonencode(s.Condition) == jsonencode({ StringEquals = { "cloudwatch:namespace" = "SecurityBaseline" } })
    ]) == 1
    error_message = "the apply roles cannot write into the namespace the baseline's alarms read"
  }
  assert {
    condition     = length(setintersection(toset([for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Action if s.Sid == "ProtectAccountSettings"][0]), toset(["ec2:DisableSnapshotBlockPublicAccess", "ssm:UpdateServiceSetting", "ssm:ResetServiceSetting", "s3:PutAccountPublicAccessBlock", "ec2:DisableEbsEncryptionByDefault"]))) == 5
    error_message = "the snapshot, SSM document, public access and EBS settings stick"
  }
  assert {
    condition     = [for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Condition.ArnEquals["ec2:Vpc"] if s.Sid == "ProtectDefaultVpc"][0] == ["arn:aws:ec2:aa-example-1:111122223333:vpc/vpc-0example00000001"]
    error_message = "rules can be added to no security group in the default VPC"
  }
  assert {
    condition = (
      [for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Resource if s.Sid == "ProtectRuleAndWebAcl"][0] == [
        "arn:aws:events:aa-example-1:111122223333:rule/security-baseline-shared-*",
        "arn:aws:wafv2:aa-example-1:111122223333:regional/webacl/security-baseline-shared-web/*",
        "arn:aws:wafv2:us-east-1:111122223333:global/webacl/security-baseline-shared-web/*",
        "arn:aws:events:*:111122223333:event-bus/default",
        "arn:aws:events:*:111122223333:event-busv2/default/*",
      ] &&
      length(aws_iam_policy.protect_web_acl) == 0 && length(aws_iam_role_policy_attachment.protect_web_acl) == 0
    )
    error_message = "the rules and the web ACL are protected by name; with no web ACL resources there is no association policy"
  }
  # Wildcard- and case-insensitive ('*' -> '.*', '?' -> '.'); Region * means both a real Region and us-east-1 must match.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
      if s.Effect == "Deny" && !contains(keys(s), "Condition") &&
      anytrue([for a in flatten([try(s.Action, [])]) : can(regex("^${replace(replace(lower(a), "*", ".*"), "?", ".")}$", "events:updateeventbus"))]) &&
      alltrue([for r in [
        "arn:aws:events:aa-example-1:111122223333:event-bus/default",
        "arn:aws:events:us-east-1:111122223333:event-bus/default",
        "arn:aws:events:aa-example-1:111122223333:event-busv2/default/0123456789abcdef",
        ] : anytrue([for p in flatten([try(s.Resource, [])]) : can(regex("^${replace(replace(p, "*", ".*"), "?", ".")}$", r))])
      ])
    ]) == 1
    error_message = "the apply roles cannot change or re-key the default event bus, in any Region"
  }
  # By name, not a count: each action must be present, not merely bring an intersection up to size.
  assert {
    condition = alltrue([
      for a in ["kms:EnableKeyRotation", "kms:RotateKeyOnDemand"] : length([
        for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
        if s.Sid == "ProtectBaselineKey" && s.Effect == "Deny" && !contains(keys(s), "Condition") &&
        contains(flatten([s.Action]), a) &&
        toset(flatten([s.Resource])) == toset([
          "arn:aws:kms:aa-example-1:111122223333:key/00000000-0000-0000-0000-000000000000",
          "arn:aws:kms:aa-example-1:111122223333:alias/security-baseline-shared",
        ])
      ]) == 1
    ])
    error_message = "the apply roles can neither change the baseline key's rotation period nor rotate it on demand"
  }
  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
      if s.Sid == "ProtectAccountSettings" && s.Effect == "Deny" && !contains(keys(s), "Condition") && s.Resource == "*" &&
      contains(flatten([s.Action]), "ec2:CreateDefaultVpc")
    ]) == 1
    error_message = "the apply roles cannot make a default VPC while the lockdown is on"
  }
  # Each wildcard covers two Accept actions; every detector switch is off by default here.
  assert {
    condition = alltrue([
      for a in [
        "guardduty:AcceptAdministratorInvitation", "guardduty:AcceptInvitation",
        "securityhub:AcceptAdministratorInvitation", "securityhub:AcceptInvitation",
        ] : length([
          for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
          if s.Sid == "ProtectDetectors" && s.Effect == "Deny" && !contains(keys(s), "Condition") && s.Resource == "*" &&
          anytrue([for p in flatten([s.Action]) : can(regex("^${replace(replace(lower(p), "*", ".*"), "?", ".")}$", lower(a)))])
      ]) == 1
    ])
    error_message = "the apply roles cannot accept a GuardDuty or Security Hub administrator invitation, whatever the detector switches say"
  }
  # length(...) == 1, not [0]: a seed here must fail the assertion, not abort on an empty index.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
      if s.Sid == "DenyAssumingPeopleRoles" && s.Effect == "Deny" && !contains(keys(s), "Condition") &&
      toset(flatten([s.Action])) == toset(["sts:AssumeRole", "sts:TagSession"]) &&
      s.Resource == ["arn:aws:iam::111122223333:role/BreakGlassAdmin", "arn:aws:iam::111122223333:role/SecurityAuditor", "arn:aws:iam::111122223333:role/DeveloperTemplate"]
    ]) == 1
    error_message = "the apply roles can never assume a people role, whether or not it exists yet, under any condition"
  }
  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
      if s.Sid == "ProtectBaselineIam" && s.Effect == "Deny" && !contains(keys(s), "Condition") && s.Action == "iam:*" &&
      s.Resource == [
        "arn:aws:iam::111122223333:role/BreakGlassAdmin", "arn:aws:iam::111122223333:role/SecurityAuditor",
        "arn:aws:iam::111122223333:role/DeveloperTemplate", "arn:aws:iam::111122223333:role/security-baseline-shared-trail-logs",
        "arn:aws:iam::111122223333:policy/security-baseline/SecurityBaselineProtect",
        "arn:aws:iam::111122223333:policy/security-baseline/SecurityBaselineProtectWebAcl",
      ]
    ]) == 1
    error_message = "the baseline roles and both protection policies are out of the apply roles' reach: every IAM action, with no condition"
  }
}

run "no_attachment_without_role_names" {
  command = plan

  variables {
    ci_apply_role_names = []
  }

  assert {
    condition     = length(aws_iam_role_policy_attachment.protect) == 0
    error_message = "with no apply role named and no DeveloperTemplate, nothing carries the policy"
  }
}

run "account_hardening" {
  command = plan

  assert {
    condition = (
      aws_iam_account_password_policy.this.minimum_password_length == 14 && aws_iam_account_password_policy.this.password_reuse_prevention == 24 &&
      aws_iam_account_password_policy.this.require_symbols && aws_iam_account_password_policy.this.require_numbers &&
      aws_iam_account_password_policy.this.require_uppercase_characters && aws_iam_account_password_policy.this.require_lowercase_characters &&
      aws_iam_account_password_policy.this.allow_users_to_change_password
    )
    error_message = "the password policy: 14 characters, 24 remembered, every character class, users change their own"
  }
  assert {
    condition = (
      aws_s3_account_public_access_block.this.account_id == "111122223333" && aws_s3_account_public_access_block.this.block_public_acls &&
      aws_s3_account_public_access_block.this.block_public_policy && aws_s3_account_public_access_block.this.ignore_public_acls &&
      aws_s3_account_public_access_block.this.restrict_public_buckets
    )
    error_message = "S3 public access is blocked for the whole account"
  }
  assert {
    condition     = aws_ebs_encryption_by_default.this.enabled && aws_ebs_snapshot_block_public_access.this.state == "block-all-sharing"
    error_message = "new EBS volumes are encrypted and snapshots cannot be shared publicly"
  }
  assert {
    condition     = aws_ssm_service_setting.document_public_sharing.setting_id == "arn:aws:ssm:aa-example-1:111122223333:servicesetting/ssm/documents/console/public-sharing-permission" && aws_ssm_service_setting.document_public_sharing.setting_value == "Disable"
    error_message = "SSM documents cannot be shared publicly"
  }
  assert {
    condition     = length(aws_accessanalyzer_analyzer.this) == 1 && aws_accessanalyzer_analyzer.this[0].analyzer_name == "security-baseline-shared-access" && aws_accessanalyzer_analyzer.this[0].type == "ACCOUNT"
    error_message = "an account analyzer reports resources shared outside the account"
  }
  assert {
    condition     = length(aws_default_security_group.this) == 1 && aws_default_security_group.this[0].vpc_id == "vpc-0example00000001" && length(aws_default_security_group.this[0].ingress) == 0 && length(aws_default_security_group.this[0].egress) == 0
    error_message = "the default security group keeps no rule"
  }
  assert {
    condition = (
      jsondecode(aws_cloudwatch_event_rule.findings["access-analyzer-findings"].event_pattern).source == ["aws.access-analyzer"] &&
      jsondecode(aws_cloudwatch_event_rule.findings["access-analyzer-findings"].event_pattern).detail.status == ["ACTIVE"] &&
      aws_cloudwatch_event_target.findings["access-analyzer-findings"].arn == "arn:aws:sns:aa-example-1:111122223333:security-baseline-shared-alerts"
    )
    error_message = "active Access Analyzer findings reach the alerts topic"
  }
}

run "no_default_vpc_nothing_to_lock" {
  command = plan

  override_data {
    target = data.aws_vpcs.default
    values = { ids = [] }
  }

  assert {
    condition     = length(aws_default_security_group.this) == 0 && !contains([for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Sid], "ProtectDefaultVpc")
    error_message = "an account without a default VPC gets neither the lockdown nor its deny"
  }
  # Unlike ProtectDefaultVpc above, this follows the lockdown switch alone, not whether a VPC exists.
  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
      if s.Sid == "ProtectAccountSettings" && s.Effect == "Deny" && !contains(keys(s), "Condition") && s.Resource == "*" &&
      contains(flatten([s.Action]), "ec2:CreateDefaultVpc")
    ]) == 1
    error_message = "without a default VPC at plan, the apply roles still cannot create one while the lockdown is on"
  }
}

run "default_vpc_lockdown_off" {
  command = plan

  variables {
    default_security_group_lockdown_enabled = false
  }

  assert {
    condition = (
      !anytrue([for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Effect == "Deny" && contains(flatten([try(s.Action, [])]), "ec2:CreateDefaultVpc")]) &&
      !contains([for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Sid], "ProtectDefaultVpc") &&
      length(aws_default_security_group.this) == 0
    )
    error_message = "with the lockdown off, nothing denies ec2:CreateDefaultVpc and the default VPC keeps its rules"
  }
}

run "options_on" {
  command = plan

  variables {
    guardduty_enabled      = true
    config_enabled         = true
    security_hub_enabled   = true
    inspector_enabled      = true
    waf_enabled            = true
    waf_resource_arns      = ["arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/production"]
    trusted_principal_arns = ["arn:aws:iam::111122223333:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_SecurityAudit_*"]
  }

  assert {
    condition = (
      aws_guardduty_detector.this[0].enable && aws_guardduty_detector.this[0].finding_publishing_frequency == "FIFTEEN_MINUTES" &&
      join(",", keys(aws_guardduty_detector_feature.this)) == "EBS_MALWARE_PROTECTION,S3_DATA_EVENTS" &&
      alltrue([for f in aws_guardduty_detector_feature.this : f.status == "ENABLED"])
    )
    error_message = "GuardDuty runs with S3 data events and EBS malware protection"
  }
  assert {
    condition = (
      jsondecode(aws_cloudwatch_event_rule.findings["guardduty-findings"].event_pattern).source == ["aws.guardduty"] &&
      jsonencode(jsondecode(aws_cloudwatch_event_rule.findings["guardduty-findings"].event_pattern).detail.severity) == jsonencode([{ numeric = [">=", 7] }])
    )
    error_message = "GuardDuty findings of severity 7 or more reach the topic"
  }
  assert {
    condition = (
      jsondecode(aws_cloudwatch_event_rule.findings["securityhub-findings"].event_pattern)["detail-type"] == ["Security Hub Findings - Imported"] &&
      jsonencode(jsondecode(aws_cloudwatch_event_rule.findings["securityhub-findings"].event_pattern).detail.findings) == jsonencode({ RecordState = ["ACTIVE"], Severity = { Label = ["CRITICAL", "HIGH"] }, Workflow = { Status = ["NEW"] } })
    )
    error_message = "new, active, critical or high Security Hub findings reach the topic"
  }
  assert {
    condition     = length(aws_cloudwatch_event_target.findings) == 3 && alltrue([for t in aws_cloudwatch_event_target.findings : t.arn == "arn:aws:sns:aa-example-1:111122223333:security-baseline-shared-alerts"])
    error_message = "every findings rule targets the alerts topic"
  }
  assert {
    condition = (
      aws_securityhub_account.this[0].enable_default_standards == false && aws_securityhub_account.this[0].control_finding_generator == "SECURITY_CONTROL" &&
      aws_securityhub_standards_subscription.foundational[0].standards_arn == "arn:aws:securityhub:aa-example-1::standards/aws-foundational-security-best-practices/v/1.0.0"
    )
    error_message = "Security Hub runs the AWS Foundational Security Best Practices standard only"
  }
  assert {
    condition = (
      aws_config_configuration_recorder.this[0].recording_mode[0].recording_frequency == "DAILY" &&
      aws_config_configuration_recorder.this[0].recording_group[0].all_supported && aws_config_configuration_recorder.this[0].recording_group[0].include_global_resource_types &&
      aws_config_delivery_channel.this[0].s3_bucket_name == "security-baseline-shared-trail-111122223333" && aws_config_delivery_channel.this[0].s3_key_prefix == "config" &&
      aws_config_delivery_channel.this[0].s3_kms_key_arn == aws_kms_key.this[0].arn && aws_config_configuration_recorder_status.this[0].is_enabled
    )
    error_message = "Config records daily into the trail bucket under config/, encrypted with the baseline key"
  }
  assert {
    condition = (
      aws_iam_service_linked_role.config[0].aws_service_name == "config.amazonaws.com" &&
      aws_config_configuration_recorder.this[0].role_arn == "arn:aws:iam::111122223333:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig"
    )
    error_message = "the recorder uses AWS Config's service-linked role, which Security Hub control Config.1 checks for"
  }
  assert {
    condition = (
      join(",", [for s in jsondecode(aws_s3_bucket_policy.trail.policy).Statement : s.Sid]) == "DenyInsecureTransport,DenyOldTls,CloudTrailAclCheck,CloudTrailWrite,DenyChangesByPipelineRoles,ConfigBucketPermissionsCheck,ConfigBucketExistenceCheck,ConfigBucketDelivery" &&
      alltrue([for s in slice(jsondecode(aws_s3_bucket_policy.trail.policy).Statement, 5, 8) :
        s.Effect == "Allow" && s.Principal.Service == "config.amazonaws.com" && s.Condition.StringEquals["aws:SourceAccount"] == "111122223333" &&
        s.Resource == (s.Action == "s3:PutObject" ? "arn:aws:s3:::security-baseline-shared-trail-111122223333/config/AWSLogs/111122223333/Config/*" : "arn:aws:s3:::security-baseline-shared-trail-111122223333")
      ]) &&
      join(",", [for s in slice(jsondecode(aws_s3_bucket_policy.trail.policy).Statement, 5, 8) : s.Action]) == "s3:GetBucketAcl,s3:ListBucket,s3:PutObject" &&
      jsondecode(aws_s3_bucket_policy.trail.policy).Statement[7].Condition.StringEquals["s3:x-amz-acl"] == "bucket-owner-full-control"
    )
    error_message = "Config, as its service principal, checks the bucket and writes only under config/AWSLogs/<account>/Config/, for this account only"
  }
  assert {
    condition = length([
      for s in jsondecode(aws_kms_key.this[0].policy).Statement : s
      if s.Sid == "ConfigDeliverSnapshots" && s.Principal.Service == "config.amazonaws.com" && join(",", s.Action) == "kms:Decrypt,kms:GenerateDataKey" &&
      s.Condition.StringEquals["aws:SourceAccount"] == "111122223333"
    ]) == 1 && jsondecode(aws_kms_key.this[0].policy).Statement[length(jsondecode(aws_kms_key.this[0].policy).Statement) - 1].Sid == "DenyPipelineRoles"
    error_message = "Config uses the baseline key for this account's deliveries only"
  }
  assert {
    condition     = aws_inspector2_enabler.this[0].resource_types == toset(["EC2", "ECR", "LAMBDA"]) && aws_inspector2_enabler.this[0].account_ids == toset(["111122223333"])
    error_message = "Inspector scans EC2, ECR and Lambda by default"
  }
  assert {
    condition = (
      aws_wafv2_web_acl.this[0].name == "security-baseline-shared-web" && aws_wafv2_web_acl.this[0].scope == "REGIONAL" && aws_wafv2_web_acl.this[0].region == "aa-example-1" &&
      toset(flatten([for r in aws_wafv2_web_acl.this[0].rule : [for s in r.statement : [for m in s.managed_rule_group_statement : m.name]]])) == toset(["AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet", "AWSManagedRulesSQLiRuleSet"]) &&
      join(",", flatten([for r in aws_wafv2_web_acl.this[0].rule : [for s in r.statement : [for b in s.rate_based_statement : "${b.limit}/${b.evaluation_window_sec}/${b.aggregate_key_type}"]]])) == "2000/300/IP" &&
      join(",", keys(aws_wafv2_web_acl_association.this)) == "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/production"
    )
    error_message = "the web ACL runs three AWS rule groups and a 2000-per-5-minutes IP limit, on the named resources"
  }
  assert {
    condition     = length(aws_iam_policy.protect.policy) <= 6144 && contains([for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Resource if s.Sid == "ProtectBaselineIam"][0], "arn:aws:iam::111122223333:role/aws-service-role/config.amazonaws.com/AWSServiceRoleForConfig")
    error_message = "with every option on, the protection policy still fits and covers the Config service-linked role"
  }
  assert {
    condition = (
      aws_iam_policy.protect_web_acl[0].name == "SecurityBaselineProtectWebAcl" && aws_iam_policy.protect_web_acl[0].path == "/security-baseline/" &&
      jsonencode(jsondecode(aws_iam_policy.protect_web_acl[0].policy).Statement) == jsonencode([{
        Action = [
          "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL", "apigateway:SetWebACL",
          "elasticloadbalancing:CreateWebACLAssociation", "elasticloadbalancing:DeleteWebACLAssociation",
        ]
        Effect   = "Deny"
        Resource = ["arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/production"]
        Sid      = "ProtectWebAclAssociations"
      }]) &&
      join(",", keys(aws_iam_role_policy_attachment.protect_web_acl)) == "DeveloperTemplate,gha-apply-dev,gha-apply-production"
    )
    error_message = "the apply roles can neither remove the web ACL from the resources it protects nor put another web ACL on them"
  }
  assert {
    condition     = alltrue([for k, v in output.controls : v if k != "break_glass_role"])
    error_message = "the controls output reports every option on"
  }
}

# The largest protection policies the variables allow: a 32-character prefix, the GovCloud partition
# (the longest ARNs), every option on and the most web ACL resources, each a load balancer with a
# 32-character name.
run "protect_policies_fit_at_their_largest" {
  command = plan

  override_data {
    target = data.aws_partition.current
    values = { partition = "aws-us-gov", dns_suffix = "amazonaws.com" }
  }

  override_resource {
    target          = aws_kms_key.this
    override_during = plan
    values = {
      arn    = "arn:aws-us-gov:kms:us-gov-west-1:111122223333:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }

  # A real 21-character VPC ID, not the fixture's 20-character one, so the fit measures the true largest.
  override_data {
    target = data.aws_vpcs.default
    values = { ids = ["vpc-0123456789abcdef0"] }
  }

  variables {
    region                     = "us-gov-west-1"
    name_prefix                = "example-service-name-long-shared"
    guardduty_enabled          = true
    config_enabled             = true
    security_hub_enabled       = true
    inspector_enabled          = true
    waf_enabled                = true
    s3_data_event_bucket_names = ["example-app-files"]
    break_glass_principal_arns = ["arn:aws-us-gov:iam::111122223333:user/example-break-glass"]
    trusted_principal_arns     = ["arn:aws-us-gov:iam::111122223333:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_SecurityAudit_*"]
    waf_resource_arns = [
      "arn:aws-us-gov:elasticloadbalancing:us-gov-west-1:111122223333:loadbalancer/app/example-load-balancer-name-00001/0123456789abcdef",
      "arn:aws-us-gov:elasticloadbalancing:us-gov-west-1:111122223333:loadbalancer/app/example-load-balancer-name-00002/0123456789abcdef",
      "arn:aws-us-gov:elasticloadbalancing:us-gov-west-1:111122223333:loadbalancer/app/example-load-balancer-name-00003/0123456789abcdef",
      "arn:aws-us-gov:elasticloadbalancing:us-gov-west-1:111122223333:loadbalancer/app/example-load-balancer-name-00004/0123456789abcdef",
      "arn:aws-us-gov:elasticloadbalancing:us-gov-west-1:111122223333:loadbalancer/app/example-load-balancer-name-00005/0123456789abcdef",
      "arn:aws-us-gov:elasticloadbalancing:us-gov-west-1:111122223333:loadbalancer/app/example-load-balancer-name-00006/0123456789abcdef",
      "arn:aws-us-gov:elasticloadbalancing:us-gov-west-1:111122223333:loadbalancer/app/example-load-balancer-name-00007/0123456789abcdef",
      "arn:aws-us-gov:elasticloadbalancing:us-gov-west-1:111122223333:loadbalancer/app/example-load-balancer-name-00008/0123456789abcdef",
      "arn:aws-us-gov:elasticloadbalancing:us-gov-west-1:111122223333:loadbalancer/app/example-load-balancer-name-00009/0123456789abcdef",
      "arn:aws-us-gov:elasticloadbalancing:us-gov-west-1:111122223333:loadbalancer/app/example-load-balancer-name-00010/0123456789abcdef",
    ]
  }

  assert {
    condition     = length(aws_iam_policy.protect.policy) <= 6144 && contains([for s in jsondecode(aws_iam_policy.protect.policy).Statement : s.Sid], "ProtectDefaultVpc")
    error_message = "SecurityBaselineProtect fits IAM's 6,144-character managed policy limit with every option on (${length(aws_iam_policy.protect.policy)})"
  }
  assert {
    condition     = length(aws_iam_policy.protect_web_acl[0].policy) <= 6144 && length(jsondecode(aws_iam_policy.protect_web_acl[0].policy).Statement[0].Resource) == 10
    error_message = "SecurityBaselineProtectWebAcl fits the same limit with the most resources waf_resource_arns allows"
  }
}

run "inspector_resource_types_are_a_choice" {
  command = plan

  variables {
    inspector_enabled        = true
    inspector_resource_types = ["LAMBDA", "LAMBDA_CODE"]
  }

  assert {
    condition     = aws_inspector2_enabler.this[0].resource_types == toset(["LAMBDA", "LAMBDA_CODE"])
    error_message = "Inspector scans what the account chose"
  }
}

run "cloudfront_waf_in_us_east_1" {
  command = plan

  variables {
    waf_enabled = true
    waf_scope   = "CLOUDFRONT"
  }

  assert {
    condition     = aws_wafv2_web_acl.this[0].region == "us-east-1" && aws_wafv2_web_acl.this[0].scope == "CLOUDFRONT" && length(aws_wafv2_web_acl_association.this) == 0 && length(aws_iam_policy.protect_web_acl) == 0
    error_message = "a CloudFront web ACL is created in us-east-1, and the distribution names it; no association policy is needed"
  }
}

run "s3_data_events_named_buckets" {
  command = plan

  variables {
    s3_data_event_bucket_names = ["example-app-files", "example-uploads"]
  }

  assert {
    condition = (
      length(aws_cloudtrail.this.event_selector) == 1 &&
      aws_cloudtrail.this.event_selector[0].read_write_type == "All" && aws_cloudtrail.this.event_selector[0].include_management_events &&
      length(aws_cloudtrail.this.event_selector[0].data_resource) == 1 &&
      aws_cloudtrail.this.event_selector[0].data_resource[0].type == "AWS::S3::Object" &&
      join(",", aws_cloudtrail.this.event_selector[0].data_resource[0].values) == "arn:aws:s3:::example-app-files/,arn:aws:s3:::example-uploads/"
    )
    error_message = "one selector: every management event, read and write, and object events for the named buckets only"
  }
}

run "rejects_security_hub_without_config" {
  command = plan
  variables {
    security_hub_enabled = true
  }
  expect_failures = [var.security_hub_enabled]
}

run "rejects_inspector_in_ap_southeast_6" {
  command = plan
  variables {
    region            = "ap-southeast-6"
    inspector_enabled = true
  }
  expect_failures = [var.inspector_enabled]
}

run "rejects_an_unknown_inspector_resource_type" {
  command = plan
  variables {
    inspector_resource_types = ["EC2", "RDS"]
  }
  expect_failures = [var.inspector_resource_types]
}

run "rejects_a_short_external_id" {
  command = plan
  variables {
    break_glass_principal_arns = ["arn:aws:iam::111122223333:user/example-break-glass"]
    break_glass_external_id    = "too-short"
  }
  expect_failures = [var.break_glass_external_id]
}

run "rejects_break_glass_users_without_external_id" {
  command = plan
  variables {
    break_glass_principal_arns = ["arn:aws:iam::111122223333:user/example-break-glass"]
    break_glass_external_id    = null
  }
  expect_failures = [var.break_glass_external_id]
}

run "rejects_a_role_as_break_glass_principal" {
  command = plan
  variables {
    break_glass_principal_arns = ["arn:aws:iam::111122223333:role/example-admin"]
  }
  expect_failures = [var.break_glass_principal_arns]
}

run "rejects_a_star_trusted_principal" {
  command = plan
  variables {
    trusted_principal_arns = ["*"]
  }
  expect_failures = [var.trusted_principal_arns]
}

run "rejects_a_bare_wildcard_role_pattern" {
  command = plan
  variables {
    trusted_principal_arns = ["arn:aws:iam::111122223333:role/*"]
  }
  expect_failures = [var.trusted_principal_arns]
}

run "rejects_a_delivery_role_as_trusted_principal" {
  command = plan
  variables {
    trusted_principal_arns = ["arn:aws:iam::111122223333:role/gha-apply-dev"]
  }
  expect_failures = [var.trusted_principal_arns]
}

run "rejects_cloudfront_with_associations" {
  command = plan
  variables {
    waf_enabled       = true
    waf_scope         = "CLOUDFRONT"
    waf_resource_arns = ["arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/production"]
  }
  expect_failures = [var.waf_resource_arns]
}

run "rejects_more_than_ten_web_acl_resources" {
  command = plan
  variables {
    waf_enabled = true
    waf_resource_arns = [
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage01",
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage02",
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage03",
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage04",
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage05",
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage06",
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage07",
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage08",
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage09",
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage10",
      "arn:aws:apigateway:aa-example-1::/restapis/a1b2c3d4e5/stages/stage11",
    ]
  }
  expect_failures = [var.waf_resource_arns]
}

run "rejects_a_workload_role_under_another_path" {
  command = plan
  variables {
    pipeline_role_patterns = ["gha-*", "svc/*"]
    trusted_principal_arns = ["arn:aws:iam::111122223333:role/svc/dev/example-function"]
  }
  expect_failures = [var.trusted_principal_arns]
}

run "rejects_retention_below_400_days" {
  command = plan
  variables {
    log_retention_days = 365
  }
  expect_failures = [var.log_retention_days]
}

run "rejects_the_trail_bucket_as_a_data_event_bucket" {
  command = plan
  variables {
    s3_data_event_bucket_names = ["security-baseline-shared-trail-111122223333"]
  }
  expect_failures = [var.s3_data_event_bucket_names]
}

run "rejects_a_bad_email" {
  command = plan
  variables {
    alert_email = "<alert email>"
  }
  expect_failures = [var.alert_email]
}

run "key_carries_the_protected_tag" {
  command = plan
  assert {
    condition     = aws_kms_key.this[0].tags["lz:protected"] == "true" && length(aws_kms_key.this[0].tags) == 1
    error_message = "The key carries the tag the protect-security-logging guardrail matches, so the organization's SCP covers it."
  }
}

run "protected_tag_follows_the_input" {
  command = plan
  variables {
    protected_key_tag = { key = "tenant-protected", value = "yes" }
  }
  assert {
    condition     = aws_kms_key.this[0].tags["tenant-protected"] == "yes" && !contains(keys(aws_kms_key.this[0].tags), "lz:protected")
    error_message = "A tenant can name the tag its own guardrail matches."
  }
}

run "protected_tag_can_be_switched_off" {
  command = plan
  variables {
    protected_key_tag = null
  }
  assert {
    condition     = length(aws_kms_key.this[0].tags) == 0
    error_message = "null leaves the key untagged."
  }
}

run "rejects_a_non_kebab_protected_tag_key" {
  command = plan
  variables {
    protected_key_tag = { key = "LzProtected", value = "true" }
  }
  expect_failures = [var.protected_key_tag]
}

run "the_protect_policy_names_follow_protect_policy_prefix" {
  command = plan

  variables {
    protect_policy_prefix = "Kit"
    ci_apply_role_names   = ["kit-apply-dev"]
  }

  assert {
    condition     = aws_iam_policy.protect.name == "KitProtect"
    error_message = "the prefix changes the first policy name"
  }
  assert {
    condition     = length(aws_iam_policy.protect_web_acl) == 0 || aws_iam_policy.protect_web_acl[0].name == "KitProtectWebAcl"
    error_message = "the prefix changes the web ACL policy name"
  }
  assert {
    condition = length([
      for s in jsondecode(aws_iam_policy.protect.policy).Statement : s
      if s.Sid == "ProtectBaselineIam" && contains(flatten([s.Resource]), "arn:aws:iam::111122223333:policy/security-baseline/KitProtect") &&
      contains(flatten([s.Resource]), "arn:aws:iam::111122223333:policy/security-baseline/KitProtectWebAcl") &&
      !contains(flatten([s.Resource]), "arn:aws:iam::111122223333:policy/security-baseline/SecurityBaselineProtect")
    ]) == 1
    error_message = "the protection policies' own ARNs in the IAM deny follow the prefix"
  }
}

run "the_web_acl_policy_name_follows_the_prefix_when_waf_is_on" {
  command = plan

  variables {
    protect_policy_prefix = "Kit"
    waf_enabled           = true
    waf_resource_arns     = ["arn:aws:apigateway:aa-example-1::/restapis/abc123/stages/dev"]
  }

  assert {
    condition     = aws_iam_policy.protect_web_acl[0].name == "KitProtectWebAcl"
    error_message = "the web ACL policy name follows the prefix"
  }
}

run "access_analyzer_off_creates_none" {
  command = plan

  variables {
    access_analyzer_enabled = false
  }

  assert {
    condition     = length(aws_accessanalyzer_analyzer.this) == 0 && output.controls.access_analyzer == false
    error_message = "with access_analyzer_enabled false no analyzer is created and the controls output says so"
  }
  assert {
    condition     = contains(keys(aws_cloudwatch_event_rule.findings), "access-analyzer-findings")
    error_message = "findings of an existing analyzer still reach the alerts topic"
  }
}

run "small_account_switches_off_key_access_logs_and_long_retention" {
  command = plan

  variables {
    kms_key_enabled           = false
    access_log_bucket_enabled = false
    log_retention_days        = 90
  }

  assert {
    condition     = length(aws_kms_key.this) == 0 && length(aws_kms_alias.this) == 0 && output.kms_key_arn == null
    error_message = "with kms_key_enabled false there is no key, no alias and no key output"
  }

  assert {
    condition     = length(aws_s3_bucket.access_logs) == 0 && aws_cloudwatch_log_group.trail.retention_in_days == 90 && aws_cloudwatch_log_group.trail.kms_key_id == null
    error_message = "no access-log bucket, a 90-day log group on the service default encryption"
  }

  assert {
    condition     = [for r in aws_s3_bucket_server_side_encryption_configuration.trail.rule : r.apply_server_side_encryption_by_default[0].sse_algorithm] == ["AES256"] && aws_sns_topic.alerts.kms_master_key_id == null
    error_message = "the trail bucket falls back to SSE-S3 and the alerts topic is unencrypted so alarms can publish"
  }
}

run "imds_defaults_are_off_unless_asked" {
  command = plan

  assert {
    condition     = length(aws_ec2_instance_metadata_defaults.this) == 0 && output.imds_tokens == null
    error_message = "by default the baseline plans no instance metadata default, so an existing caller sees no change"
  }
}

run "imds_v2_required_in_the_home_region" {
  command = plan

  variables {
    imds_v2_required = true
  }

  assert {
    condition = (
      keys(aws_ec2_instance_metadata_defaults.this) == ["aa-example-1"] &&
      aws_ec2_instance_metadata_defaults.this["aa-example-1"].http_tokens == "required" &&
      aws_ec2_instance_metadata_defaults.this["aa-example-1"].http_put_response_hop_limit == 2 &&
      aws_ec2_instance_metadata_defaults.this["aa-example-1"].region == "aa-example-1"
    )
    error_message = "IMDSv2 tokens are required with hop limit 2, keyed by the home Region"
  }

  assert {
    condition     = output.imds_tokens == "required"
    error_message = "the imds_tokens output reports the mode"
  }
}

run "imds_v2_refused_in_the_wrong_account" {
  command = plan

  variables {
    imds_v2_required = true
    account_id       = "999999999999"
  }

  expect_failures = [aws_ec2_instance_metadata_defaults.this]
}
