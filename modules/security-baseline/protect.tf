# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# SecurityBaselineProtect: deny-only, attached to the account's apply roles and to DeveloperTemplate
# when it exists, so the delivery pipeline cannot directly switch off, re-point or hide what this
# baseline set up, nor take on a people role.
# A customer managed policy, not an inline one: the apply roles already carry four inline policies,
# which share IAM's 10,240-character inline total; a managed policy has its own 6,144 characters,
# and wildcards keep it well inside that (a test checks). The resources the web ACL protects are
# named in a second one, SecurityBaselineProtectWebAcl, so their number cannot push the first past
# its limit.
# The workload roles the apply roles create are bound by the bootstrap's workload boundary instead
# (templates/bootstrap, ProtectSecurityBaseline, ProtectSecurityBaselineLogs, ProtectLogsAccountPolicies
# and ProtectSecurityBaselineMetrics): it denies them changes to the baseline's topic, subscriptions and
# rules, every logs action on its log group except reading and querying the events, account-level logs
# policies, and writes into the SecurityBaseline metric namespace, by names starting security-baseline-
# (the root's default service name). Still open, here and in the boundary: reading the trail's events.
# The log-group resource policy is an accepted risk, not an open route: logs:PutResourcePolicy names
# no resource in IAM, so no log-group deny reaches it, and such a policy lets only an AWS service write
# events into a group. The trail files in the bucket are untouched, and the trail-delivery alarm fires
# when the log group stops receiving events.

locals {
  # The people-role names are covered whether or not the roles exist yet, so nobody else takes them.
  baseline_role_arns = concat(
    local.people_role_arns,
    ["${local.iam_prefix}:role/${local.prefix}-trail-logs"],
    var.config_enabled ? [local.config_role_arn] : [],
  )
  log_bucket_arns = concat(
    [local.trail_bucket_arn, "${local.trail_bucket_arn}/*"],
    local.access_log_on ? [local.access_log_bucket_arn, "${local.access_log_bucket_arn}/*"] : [],
  )
  default_vpc_arns = [for id in data.aws_vpcs.default.ids : "arn:${local.partition}:ec2:${var.region}:${var.account_id}:vpc/${id}"]

  # All the delivery roles keep on the trail log group: reading and querying its events.
  log_group_reads = [
    "logs:Get*", "logs:Describe*", "logs:List*", "logs:FilterLogEvents", "logs:StartQuery", "logs:StopQuery",
    "logs:GetQueryResults", "logs:StartLiveTail", "logs:StopLiveTail",
  ]

  protect_candidates = [
    {
      on = true
      statement = {
        Sid      = "ProtectTrail"
        Effect   = "Deny"
        Action   = ["cloudtrail:Stop*", "cloudtrail:Delete*", "cloudtrail:Update*", "cloudtrail:Put*", "cloudtrail:RemoveTags"]
        Resource = local.trail_arn
      }
    },
    {
      # Every other logs action on the trail log group and its streams: tags, key, retention, filters,
      # transformer, masking, subscriptions, exports, new events. IAM compares Resource with the resource
      # a request names, and only CloudWatch Logs actions name a log group, so this deny reaches no
      # other service, nor a logs action that names no resource (account policies are denied below).
      on = true
      statement = {
        Sid       = "ProtectTrailLogGroup"
        Effect    = "Deny"
        NotAction = local.log_group_reads
        Resource  = [local.log_group_arn, "${local.log_group_arn}:*"]
      }
    },
    {
      # Only the baseline's own alarms: the workload roots keep managing theirs.
      on = true
      statement = {
        Sid      = "ProtectAlarmsAndDashboard"
        Effect   = "Deny"
        Action   = ["cloudwatch:Put*", "cloudwatch:Delete*", "cloudwatch:Disable*", "cloudwatch:SetAlarmState", "cloudwatch:Untag*"]
        Resource = ["${local.alarm_arn_prefix}${local.prefix}-*", "arn:${local.partition}:cloudwatch::${var.account_id}:dashboard/${local.dashboard_name}"]
      }
    },
    {
      # PutMetricData names no resource; the namespace condition keeps the apply roles out of the alarms' metrics.
      on = true
      statement = {
        Sid       = "ProtectBaselineMetrics"
        Effect    = "Deny"
        Action    = "cloudwatch:PutMetricData"
        Resource  = "*"
        Condition = { StringEquals = { "cloudwatch:namespace" = local.metric_namespace } }
      }
    },
    {
      on = true
      statement = {
        Sid    = "ProtectAlertsTopic"
        Effect = "Deny"
        Action = [
          "sns:Delete*", "sns:Set*", "sns:*Permission", "sns:Subscribe", "sns:Unsubscribe", "sns:PutDataProtectionPolicy",
          "sns:Untag*",
        ]
        Resource = [local.topic_arn, "${local.topic_arn}:*"]
      }
    },
    {
      on = var.kms_key_enabled
      statement = {
        Sid    = "ProtectBaselineKey"
        Effect = "Deny"
        Action = [
          "kms:ScheduleKeyDeletion", "kms:Disable*", "kms:PutKeyPolicy", "kms:*Grant", "kms:Decrypt", "kms:ReEncrypt*",
          "kms:GenerateDataKey*", "kms:Update*", "kms:DeleteAlias", "kms:Untag*", "kms:EnableKeyRotation", "kms:RotateKeyOnDemand",
        ]
        Resource = [local.kms_arn, local.key_alias_arn]
      }
    },
    {
      on = true
      statement = {
        Sid      = "ProtectLogBuckets"
        Effect   = "Deny"
        Action   = concat(local.bucket_settings, local.log_object_writes)
        Resource = local.log_bucket_arns
      }
    },
    {
      # Account-level CloudWatch Logs policies (PutAccountPolicy) reach the trail log group without
      # naming it: a data protection policy masks what its metric filters see, a transformer policy
      # reshapes the events they match, and a subscription filter policy copies the events out.
      on = true
      statement = {
        Sid    = "ProtectAccountSettings"
        Effect = "Deny"
        # ec2:CreateDefaultVpc follows the lockdown switch itself, not whether a default VPC exists at
        # plan: recreating one would only put the emptied default security group's rules back in play.
        Action = concat([
          "s3:PutAccountPublicAccessBlock", "ec2:DisableEbsEncryptionByDefault", "ec2:ModifyEbsDefaultKmsKeyId",
          "ec2:ResetEbsDefaultKmsKeyId", "ec2:DisableSnapshotBlockPublicAccess", "ec2:EnableSnapshotBlockPublicAccess",
          "ssm:UpdateServiceSetting", "ssm:ResetServiceSetting", "iam:UpdateAccountPasswordPolicy",
          "iam:DeleteAccountPasswordPolicy", "access-analyzer:Delete*", "access-analyzer:*ArchiveRule",
          "access-analyzer:UpdateFindings", "logs:PutAccountPolicy", "logs:DeleteAccountPolicy",
          ], var.default_security_group_lockdown_enabled ? ["ec2:CreateDefaultVpc"] : [],
        )
        Resource = "*"
      }
    },
    {
      on = var.default_security_group_lockdown_enabled && length(local.default_vpc_arns) > 0
      statement = {
        Sid       = "ProtectDefaultVpc"
        Effect    = "Deny"
        Action    = ["ec2:AuthorizeSecurityGroup*", "ec2:ModifySecurityGroupRules", "ec2:UpdateSecurityGroupRuleDescriptions*"]
        Resource  = "arn:${local.partition}:ec2:${var.region}:${var.account_id}:security-group/*"
        Condition = { ArnEquals = { "ec2:Vpc" = local.default_vpc_arns } }
      }
    },
    {
      # Every detector, whether this baseline or someone else switched it on.
      on = true
      statement = {
        Sid    = "ProtectDetectors"
        Effect = "Deny"
        Action = [
          "guardduty:Delete*", "guardduty:Update*", "guardduty:Disassociate*", "guardduty:StopMonitoringMembers",
          "guardduty:Create*", "guardduty:Accept*", "securityhub:Disable*", "securityhub:BatchDisable*", "securityhub:Update*",
          "securityhub:BatchUpdate*", "securityhub:*AutomationRule*", "securityhub:Disassociate*", "securityhub:Accept*",
          "inspector2:Disable*", "inspector2:Update*", "inspector2:CreateFilter", "config:Stop*", "config:Delete*", "config:Put*",
        ]
        Resource = "*"
      }
    },
    {
      # Folds in the default event bus the findings rules run on: IAM lists UpdateEventBus under either
      # ARN form, Region * because the bus is account-wide. events:PutEvents stays allowed, undenied.
      on = true
      statement = {
        Sid    = "ProtectRuleAndWebAcl"
        Effect = "Deny"
        Action = [
          "events:DeleteRule", "events:DisableRule", "events:PutRule", "events:PutTargets", "events:RemoveTargets",
          "events:UpdateEventBus", "wafv2:DeleteWebACL", "wafv2:UpdateWebACL", "wafv2:DeleteLoggingConfiguration",
        ]
        Resource = [
          local.rule_arn_pattern,
          "arn:${local.partition}:wafv2:${var.region}:${var.account_id}:regional/webacl/${local.web_acl_name}/*",
          "arn:${local.partition}:wafv2:us-east-1:${var.account_id}:global/webacl/${local.web_acl_name}/*",
          "arn:${local.partition}:events:*:${var.account_id}:event-bus/default",
          "arn:${local.partition}:events:*:${var.account_id}:event-busv2/default/*",
        ]
      }
    },
    {
      on = true
      statement = {
        Sid      = "DenyAssumingPeopleRoles"
        Effect   = "Deny"
        Action   = ["sts:AssumeRole", "sts:TagSession"]
        Resource = local.people_role_arns
      }
    },
    {
      on = true
      statement = {
        Sid      = "ProtectBaselineIam"
        Effect   = "Deny"
        Action   = "iam:*"
        Resource = concat(local.baseline_role_arns, local.protect_policy_arns)
      }
    },
  ]

  protect_policy = {
    Version   = "2012-10-17"
    Statement = [for c in local.protect_candidates : c.statement if c.on]
  }

  # Associating or removing a web ACL names the protected resource: AWS WAF checks it for wafv2:*WebACL,
  # API Gateway for SetWebACL on the stage, and a load balancer for its web ACL association actions.
  web_acl_protect_on = var.waf_enabled && length(var.waf_resource_arns) > 0
  web_acl_protect_policy = {
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ProtectWebAclAssociations"
      Effect = "Deny"
      Action = [
        "wafv2:AssociateWebACL", "wafv2:DisassociateWebACL", "apigateway:SetWebACL",
        "elasticloadbalancing:CreateWebACLAssociation", "elasticloadbalancing:DeleteWebACLAssociation",
      ]
      Resource = var.waf_resource_arns
    }]
  }

  # Each apply role named, and DeveloperTemplate when it exists.
  protected_roles = concat(var.ci_apply_role_names, local.people_on ? ["DeveloperTemplate"] : [])
}

resource "aws_iam_policy" "protect" {
  name        = local.protect_policy_names[0]
  path        = "/security-baseline/"
  description = "Keeps the delivery roles away from the ${local.prefix} trail, logs, alarms, topic, key, account settings and detectors"
  policy      = jsonencode(local.protect_policy)
}

resource "aws_iam_role_policy_attachment" "protect" {
  for_each   = toset(local.protected_roles)
  role       = each.key
  policy_arn = aws_iam_policy.protect.arn

  depends_on = [aws_iam_role.people]
}

resource "aws_iam_policy" "protect_web_acl" {
  count       = local.web_acl_protect_on ? 1 : 0
  name        = local.protect_policy_names[1]
  path        = "/security-baseline/"
  description = "Keeps the delivery roles from moving the ${local.web_acl_name} web ACL off the resources it protects"
  policy      = jsonencode(local.web_acl_protect_policy)
}

resource "aws_iam_role_policy_attachment" "protect_web_acl" {
  for_each   = toset(local.web_acl_protect_on ? local.protected_roles : [])
  role       = each.key
  policy_arn = aws_iam_policy.protect_web_acl[0].arn

  depends_on = [aws_iam_role.people]
}
