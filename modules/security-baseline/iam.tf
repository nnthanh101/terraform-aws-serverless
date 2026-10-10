# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# The people roles, each for one hour, each existing only once someone is named for it.
# BreakGlassAdmin is the administrator for emergencies: only the IAM users named, signed in with MFA
# within the hour, presenting the external ID the root generated; every use raises an alarm.
# SecurityAuditor and DeveloperTemplate trust the account, but only the principals named pass:
# trusting the account alone would let the delivery roles in, since PowerUserAccess allows sts:*.
# IAM users named need an MFA sign-in within the hour: Bool, not BoolIfExists, because a call made
# with long-term access keys carries no MFA key at all. Roles named (Identity Center roles by
# pattern) pass without an MFA key: their sessions do not carry it, so MFA for them is set in
# Identity Center's sign-in settings.

locals {
  trusted_users = [for a in var.trusted_principal_arns : a if can(regex(":user/", a))]
  trusted_roles = [for a in var.trusted_principal_arns : a if !can(regex(":user/", a))]

  people_trust = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [for s in [{
        Sid       = "NamedUsersWithRecentMfa"
        Effect    = "Allow"
        Principal = { AWS = "${local.iam_prefix}:root" }
        Action    = "sts:AssumeRole"
        Condition = {
          ArnLike         = { "aws:PrincipalArn" = local.trusted_users }
          Bool            = { "aws:MultiFactorAuthPresent" = "true" }
          NumericLessThan = { "aws:MultiFactorAuthAge" = 3600 }
        }
      }] : s if length(local.trusted_users) > 0],
      [for s in [{
        Sid       = "NamedRoles"
        Effect    = "Allow"
        Principal = { AWS = "${local.iam_prefix}:root" }
        Action    = "sts:AssumeRole"
        Condition = { ArnLike = { "aws:PrincipalArn" = local.trusted_roles } }
      }] : s if length(local.trusted_roles) > 0],
    )
  })

  role_trusts = {
    BreakGlassAdmin = jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Sid       = "NamedUsersWithRecentMfaAndExternalId"
        Effect    = "Allow"
        Principal = { AWS = var.break_glass_principal_arns }
        Action    = "sts:AssumeRole"
        Condition = {
          StringEquals    = { "sts:ExternalId" = var.break_glass_external_id }
          Bool            = { "aws:MultiFactorAuthPresent" = "true" }
          NumericLessThan = { "aws:MultiFactorAuthAge" = 3600 }
        }
      }]
    })
    SecurityAuditor   = local.people_trust
    DeveloperTemplate = local.people_trust
  }

  role_descriptions = {
    BreakGlassAdmin   = "Administrator for emergencies: named users, external ID, recent MFA, one hour, and an alarm on every use"
    SecurityAuditor   = "Reads security settings and the trail, changes nothing"
    DeveloperTemplate = "Reads everything, reads logs and invokes functions of the developer environments only"
  }

  people_roles = concat(
    local.break_glass_on ? ["BreakGlassAdmin"] : [],
    local.people_on ? ["SecurityAuditor", "DeveloperTemplate"] : [],
  )

  aws_policy = "arn:${local.partition}:iam::aws:policy"
  managed_attachments = local.people_on ? {
    "SecurityAuditor/SecurityAudit"    = { role = "SecurityAuditor", policy_arn = "${local.aws_policy}/SecurityAudit" }
    "SecurityAuditor/ViewOnlyAccess"   = { role = "SecurityAuditor", policy_arn = "${local.aws_policy}/job-function/ViewOnlyAccess" }
    "DeveloperTemplate/ViewOnlyAccess" = { role = "DeveloperTemplate", policy_arn = "${local.aws_policy}/job-function/ViewOnlyAccess" }
  } : {}

  developer_log_groups = [for e in var.developer_environments : "arn:${local.partition}:logs:${var.region}:${var.account_id}:log-group:*-${e}-*"]
  developer_functions  = [for e in var.developer_environments : "arn:${local.partition}:lambda:${var.region}:${var.account_id}:function:*-${e}-*"]
  developer_log_reads  = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults"]
}

resource "aws_iam_role" "people" {
  for_each             = toset(local.people_roles)
  name                 = each.key
  path                 = "/"
  description          = local.role_descriptions[each.key]
  assume_role_policy   = local.role_trusts[each.key]
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "break_glass_admin" {
  # checkov:skip=CKV_AWS_274:0024 administrator by design, for named users only, behind the external ID, recent MFA, one-hour sessions and the break-glass-use alarm
  count      = local.break_glass_on ? 1 : 0
  role       = aws_iam_role.people["BreakGlassAdmin"].name
  policy_arn = "${local.aws_policy}/AdministratorAccess"
}

resource "aws_iam_role_policy_attachment" "people" {
  for_each   = local.managed_attachments
  role       = aws_iam_role.people[each.value.role].name
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy" "auditor_read_trail" {
  count = local.people_on ? 1 : 0
  name  = "ReadTrailLogs"
  role  = aws_iam_role.people["SecurityAuditor"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Sid = "TrailFiles", Effect = "Allow", Action = "s3:GetObject", Resource = "${local.trail_bucket_arn}/*" },
      { Sid = "TrailBucket", Effect = "Allow", Action = "s3:ListBucket", Resource = local.trail_bucket_arn },
      ], var.kms_key_enabled ? [{
        Sid       = "TrailKeyThroughS3AndLogs"
        Effect    = "Allow"
        Action    = "kms:Decrypt"
        Resource  = local.kms_arn
        Condition = { StringEquals = { "kms:ViaService" = [local.s3_via, local.logs_via] } }
      }] : [], [
      {
        Sid      = "TrailLogGroup"
        Effect   = "Allow"
        Action   = ["logs:StartQuery", "logs:GetQueryResults", "logs:FilterLogEvents"]
        Resource = [local.log_group_arn, "${local.log_group_arn}:*"]
      },
    ])
  })
}

resource "aws_iam_role_policy" "developer_environments" {
  count = local.people_on ? 1 : 0
  name  = "DeveloperEnvironments"
  role  = aws_iam_role.people["DeveloperTemplate"].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DeveloperLogs"
        Effect   = "Allow"
        Action   = local.developer_log_reads
        Resource = concat(local.developer_log_groups, [for a in local.developer_log_groups : "${a}:*"])
      },
      { Sid = "DeveloperFunctions", Effect = "Allow", Action = "lambda:InvokeFunction", Resource = local.developer_functions },
      {
        # X-Ray trace reads name no resource; metric reads cover every namespace.
        Sid      = "TracesAndMetrics"
        Effect   = "Allow"
        Action   = ["xray:BatchGetTraces", "xray:GetTraceSummaries", "cloudwatch:GetMetricData"]
        Resource = "*"
      },
      {
        # Whatever a name matches, production data stays out of reach.
        Sid       = "DenyProductionData"
        Effect    = "Deny"
        Action    = concat(local.developer_log_reads, ["lambda:InvokeFunction"])
        Resource  = "*"
        Condition = { StringEquals = { "aws:ResourceTag/environment" = var.production_environments } }
      },
    ]
  })
}
