# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Derived from the terraform-aws plugin's bootstrap template. See NOTICE.txt.

# Guardrail for the automation identity. A person attaches this document as the inline
# policy of the automation's read-only permission sets (AutomationReadOnly and
# AutomationReadOnlyProd). ReadOnlyAccess already has no writes; these denies hold even if
# a broader policy is added later, and they close the reads ReadOnlyAccess leaves open.
locals {
  guardrail_write_actions = flatten([for svc, verbs in {
    iam            = ["Create*", "Delete*", "Put*", "Attach*", "Detach*", "Update*", "Add*", "Remove*", "Upload*", "Set*", "PassRole"]
    organizations  = ["Create*", "Delete*", "Update*", "Attach*", "Detach*", "Move*", "Leave*", "Enable*", "Disable*", "Put*"]
    sso            = ["Create*", "Delete*", "Put*", "Update*", "Attach*", "Detach*", "Provision*"]
    lambda         = ["Create*", "Delete*", "Update*", "Put*", "Add*", "Remove*", "Publish*"]
    states         = ["Create*", "Delete*", "Update*", "Start*", "Stop*", "Send*", "Redrive*"]
    apigateway     = ["POST", "PUT", "PATCH", "DELETE"]
    dynamodb       = ["Create*", "Delete*", "Update*", "Put*", "BatchWrite*", "Restore*", "Import*"]
    s3             = ["Create*", "Delete*", "Put*", "Restore*", "Replicate*", "Bypass*"]
    sqs            = ["Create*", "Delete*", "Send*", "Purge*", "Set*"]
    sns            = ["Create*", "Delete*", "Publish", "Set*", "Subscribe"]
    events         = ["Create*", "Delete*", "Put*", "Update*", "Remove*"]
    logs           = ["Create*", "Delete*", "Put*"]
    kms            = ["Create*", "Delete*", "Put*", "Update*", "Schedule*", "Disable*", "Encrypt", "Retire*", "Revoke*"]
    secretsmanager = ["Create*", "Delete*", "Put*", "Update*", "Restore*", "Rotate*"]
    ssm            = ["Create*", "Delete*", "Put*", "Update*", "Send*", "Start*"]
    cloudformation = ["Create*", "Delete*", "Update*", "Execute*"]
    ecs            = ["Create*", "Delete*", "Update*", "Run*", "Start*", "Stop*", "Execute*", "Register*"]
    ecr            = ["Put*", "Delete*", "BatchDelete*", "CompleteLayerUpload"]
    ec2            = ["Create*", "Delete*", "Modify*", "Run*", "Terminate*", "Authorize*"]
    cloudfront     = ["Create*", "Delete*", "Update*"]
    route53        = ["Change*", "Create*", "Delete*"]
    budgets        = ["ModifyBudget"]
    # Audit, identity, edge and schedule changes, and calls into deployed APIs.
    cloudtrail    = ["Create*", "Delete*", "Put*", "Stop*", "Update*"]
    identitystore = ["Create*", "Delete*", "Update*"]
    config        = ["Delete*", "Put*", "Start*", "Stop*"]
    wafv2         = ["Associate*", "Create*", "Delete*", "Disassociate*", "Put*", "Update*"]
    cloudwatch    = ["DeleteAlarms", "DisableAlarmActions", "PutCompositeAlarm", "PutMetricAlarm", "SetAlarmState"]
    scheduler     = ["Create*", "Delete*", "Update*"]
    execute-api   = ["Invoke", "ManageConnections"]
    acm           = ["Delete*", "Import*", "Request*", "Update*"]
    cognito-idp   = ["Admin*", "Create*", "Delete*", "Update*"]
    backup        = ["Delete*", "Put*", "Start*", "Stop*", "Update*"]
    guardduty     = ["Delete*", "Disable*", "Update*"]
    securityhub   = ["Delete*", "Disable*", "Update*"]
  } : [for v in verbs : "${svc}:${v}"]])

  # Calls made through the AWS MCP service may only read.
  guardrail_mcp_read_actions = flatten([for svc in [
    "sts", "iam", "organizations", "lambda", "states", "apigateway", "dynamodb", "s3", "sqs", "sns", "events", "logs",
    "cloudwatch", "xray", "kms", "ssm", "cloudformation", "ecs", "ecr", "ec2", "cloudfront", "route53", "ce", "budgets",
    "config", "cloudtrail", "health", "tag",
  ] : [for v in ["Describe*", "Get*", "List*"] : "${svc}:${v}"]])

  automation_guardrail = {
    Version = "2012-10-17"
    Statement = [
      { Sid = "DenyWrites", Effect = "Deny", Action = local.guardrail_write_actions, Resource = "*" },
      {
        Sid       = "DenyMcpNonRead"
        Effect    = "Deny"
        NotAction = local.guardrail_mcp_read_actions
        Resource  = "*"
        Condition = { Bool = { "aws:ViaAWSMCPService" = "true" } }
      },
      {
        Sid      = "DenySecretReads"
        Effect   = "Deny"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue"]
        Resource = "*"
      },
      {
        Sid       = "DenyDecryptOutsideState"
        Effect    = "Deny"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*"]
        Resource  = "*"
        Condition = { StringNotEquals = { "kms:ViaService" = local.s3_via } }
      },
      {
        Sid         = "DenyObjectReadsOutsideState"
        Effect      = "Deny"
        Action      = ["s3:GetObject", "s3:GetObjectVersion"]
        NotResource = ["${local.bucket_arn}/*"]
      },
      {
        Sid      = "DenyProductionStateAndPlans"
        Effect   = "Deny"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = concat(local.production_state_arns, ["${local.bucket_arn}/plans/*"])
      },
      {
        Sid    = "DenyDataPlaneReads"
        Effect = "Deny"
        Action = [
          "dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:PartiQLSelect", "dynamodb:GetRecords",
          "sqs:ReceiveMessage", "lambda:Invoke*", "states:DescribeExecution", "states:GetExecutionHistory", "states:GetActivityTask",
        ]
        Resource = "*"
      },
      {
        # GetApiKey, GetApiKeys and GetUsagePlanKey(s) return key values.
        Sid      = "DenyApiKeyValues"
        Effect   = "Deny"
        Action   = "apigateway:GET"
        Resource = local.api_key_arns
      },
      {
        Sid    = "DenyTokenCalls"
        Effect = "Deny"
        Action = [
          "sts:AssumeRole*", "sts:GetFederationToken", "sts:GetSessionToken", "sts:GetServiceBearerToken",
          "ecr:GetAuthorizationToken", "codeartifact:GetAuthorizationToken", "ec2:GetPasswordData",
          "rds-db:connect", "redshift:GetClusterCredentials",
        ]
        Resource = "*"
      },
    ]
  }
}

output "state_bucket_name" {
  description = "S3 bucket for Terraform state (keys <service>/<environment>/terraform.tfstate) and saved plans (plans/<run_id>/)."
  value       = aws_s3_bucket.state.bucket
}

output "state_bucket_arn" {
  description = "ARN of the state bucket."
  value       = aws_s3_bucket.state.arn
}

output "state_bucket_region" {
  description = "AWS Region the state bucket resides in."
  value       = aws_s3_bucket.state.bucket_region
}

output "state_kms_key_arn" {
  description = "Customer managed key for state and saved plans; null when create_state_kms_key is false. Put it in each backend.hcl as kms_key_id when it is set."
  value       = local.state_key_arn
}

output "backend_settings" {
  description = "Values for envs/<env>.backend.hcl in each workload root (add key = \"<service>/<env>/terraform.tfstate\")."
  value = {
    bucket       = aws_s3_bucket.state.bucket
    region       = var.region
    kms_key_id   = local.state_key_arn
    encrypt      = true
    use_lockfile = true
  }
}

output "oidc_provider_arn" {
  description = "GitHub Actions OIDC provider the roles trust: the one this module created, or oidc_provider_arn when create_oidc_provider = false. Null with ci_roles = false."
  value       = var.ci_roles ? (var.create_oidc_provider ? one(aws_iam_openid_connect_provider.github[*].arn) : var.oidc_provider_arn) : null
}

output "plan_role_names" {
  description = "Read-only plan roles, for the trust check's --plan-roles. <prefix>-plan-pr plans pull requests and cannot read production state; <prefix>-plan-default plans production after merge and saves the plan. Empty with ci_roles = false."
  value       = [for k in ["pr", "default"] : aws_iam_role.plan[k].name if contains(keys(aws_iam_role.plan), k)]
}

output "plan_role_arns" {
  description = "Repository variables PLAN_PR_ROLE_ARN and PLAN_DEFAULT_ROLE_ARN. Empty with ci_roles = false."
  value       = { for k, r in aws_iam_role.plan : k => r.arn }
}

output "apply_role_arns" {
  description = "One apply role per environment, for the variables APPLY_ROLE_ARN_<ENV>. Empty with ci_roles = false."
  value       = { for e, r in aws_iam_role.apply : e => r.arn }
}

output "apply_role_names" {
  description = "One apply role name per environment. The names are known at plan, so a caller that passes them on (for example to the security baseline's ci_apply_role_names) waits for the roles without a module-level depends_on. Empty with ci_roles = false."
  value       = { for e, r in aws_iam_role.apply : e => r.name }
}

output "workload_boundary_policy_arns" {
  description = "Permissions boundary per environment. Each workload root sets permissions_boundary_arn to its own environment's entry. Empty with ci_roles = false."
  value       = { for e, p in aws_iam_policy.workload_boundary : e => p.arn }
}

output "workload_role_paths" {
  description = "IAM path per environment under which apply roles may create and pass workload roles. Empty with ci_roles = false."
  value       = { for e in local.ci_environments : e => "/${var.service_role_path}/${e}/" }
}

output "budget_name" {
  description = "Monthly account budget that notifies the budget owner at 80% and 100% of actual cost, and when the forecast passes 100%."
  value       = aws_budgets_budget.account.name
}

output "automation_guardrail_policy_json" {
  description = "Inline policy for the automation's read-only permission sets: denies writes, secrets, data-plane reads, API key values, token calls and non-read calls made through the AWS MCP service."
  value       = jsonencode(local.automation_guardrail)
}

output "break_glass_user_arn" {
  description = "The break-glass user's ARN, or null when break_glass_user is false. Its password and MFA are set in the console."
  value       = var.break_glass_user ? aws_iam_user.break_glass[0].arn : null
}
