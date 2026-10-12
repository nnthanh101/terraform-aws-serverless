# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Derived from the terraform-aws plugin's bootstrap template. See NOTICE.txt.
#
# Per-tenant foundation for CI-only delivery. A person applies this once per account (or once per
# tenant in a shared account), with an administrator profile and a local backend, outside CI.
# It creates the state bucket and key, the GitHub OIDC provider (optional), the GitHub roles
# (two read-only plan roles, one apply role per environment), one workload boundary per
# environment, an account budget, and the guardrail policy for the automation identity (outputs.tf).
# With ci_roles = false (an organization's management account) it creates no GitHub trust, role or boundary.

data "aws_partition" "current" {}

# The caller configures the provider; the state key's preconditions compare it with the inputs.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  dns_suffix = data.aws_partition.current.dns_suffix
  iam_prefix = "arn:${local.partition}:iam::${var.account_id}"

  # Per-tenant names. The prefix gha keeps the names the first tenant in an account has always
  # had; any other prefix goes in front of every per-tenant name, so two tenants never collide.
  tenant_prefix = var.name_prefix == "gha" ? "" : "${var.name_prefix}-"
  name_base     = "${local.tenant_prefix}${var.service}"
  bucket_name   = coalesce(var.state_bucket_name, "${var.account_id}-${local.tenant_prefix}tfstate-${var.region}")

  # The token issuer the roles trust: GitHub Actions, or one Azure DevOps organization.
  ado         = var.ci_platform == "azure-devops"
  issuer_host = local.ado ? "vstoken.dev.azure.com/${coalesce(var.ado_organization_id, "none")}" : "token.actions.githubusercontent.com"
  oidc_aud    = local.ado ? "api://AzureADTokenExchange" : "sts.amazonaws.com"
  oidc_arn    = var.create_oidc_provider ? "${local.iam_prefix}:oidc-provider/${local.issuer_host}" : var.oidc_provider_arn
  bucket_arn  = "arn:${local.partition}:s3:::${local.bucket_name}"
  s3_via      = "s3.${var.region}.${local.dns_suffix}"
  # Every delivery role of this tenant, and every workload role its apply roles create.
  delivery_role_arns = "${local.iam_prefix}:role/${var.name_prefix}-*"
  workload_role_arns = "${local.iam_prefix}:role/${var.service_role_path}/*"

  apply_policy_arns = var.apply_policy_arns != null ? var.apply_policy_arns : ["arn:${local.partition}:iam::aws:policy/PowerUserAccess"]

  # A key in var.tags replaces the module's own key of the same name (exact match; keys are validated kebab-case).
  own_tags = { environment = "shared", service = var.service, managed-by = "terraform", change = var.change_id }
  tags     = merge({ for k, v in local.own_tags : k => v if v != null && !contains(keys(var.tags), k) }, var.tags)

  # One boundary per environment, so a role created for dev can never carry production's rights.
  boundary_arns = { for e in var.environments : e => "${local.iam_prefix}:policy/${local.name_base}-${e}-workload-boundary" }
  budget_name   = "${local.name_base}-shared-monthly-cost"

  # Bucket settings of the state bucket. Only the person who applies the bootstrap changes them.
  # PowerUserAccess would otherwise let an apply role turn on Requester Pays (every backend call
  # fails), Object Lock (irreversible), or send object names out through notifications, logging,
  # inventory, analytics, replication or metadata tables.
  state_bucket_settings = [
    "s3:DeleteBucket*", "s3:PutBucket*", "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration",
    "s3:PutReplicationConfiguration", "s3:PutInventoryConfiguration", "s3:PutAnalyticsConfiguration",
    "s3:PutMetricsConfiguration", "s3:PutIntelligentTieringConfiguration", "s3:PutAccelerateConfiguration",
    "s3:CreateBucketMetadata*", "s3:UpdateBucketMetadata*",
  ]

  # API key values: GetApiKey, GetApiKeys and GetUsagePlanKey(s) return them in the response.
  api_key_arns = [
    "arn:${local.partition}:apigateway:*::/apikeys",
    "arn:${local.partition}:apigateway:*::/apikeys/*",
    "arn:${local.partition}:apigateway:*::/usageplans/*/keys",
    "arn:${local.partition}:apigateway:*::/usageplans/*/keys/*",
  ]

  # Plan roles: read-only, one for pull requests and one for the default branch. With ci_roles off
  # (an organization's management account, applied by a person) there is no CI role at all.
  plan_roles = var.ci_roles ? {
    pr      = { name = "${var.name_prefix}-plan-pr", suffix = "pull_request" }
    default = { name = "${var.name_prefix}-plan-default", suffix = "ref:refs/heads/${var.default_branch}" }
  } : {}
  ci_environments = var.ci_roles ? toset(var.environments) : toset([])

  # Every GitHub trust is StringEquals on an exact sub per repository and on aud. Apply roles
  # trust only their GitHub Environment, which carries the named approver, and, when
  # apply_workflow_refs lists the environment, only those workflows.
  github_roles = merge(
    { for k, r in local.plan_roles : r.name => { suffix = r.suffix, workflow_refs = [] } },
    { for e in local.ci_environments : "${var.name_prefix}-apply-${e}" => { suffix = "environment:${e}", workflow_refs = lookup(var.apply_workflow_refs, e, []) } }
  )
  # GitHub's immutable subject (repositories created after 2026-07-15) is repo:<org>@<id>/<repo>@<id>;
  # a name-based subject never matches it, so the prefix comes from the repository settings when given.
  subject_prefixes = length(var.github_subject_prefixes) > 0 ? var.github_subject_prefixes : [for repo in var.github_repositories : "repo:${repo}"]
  role_subs        = { for name, r in local.github_roles : name => [for p in local.subject_prefixes : "${p}:${r.suffix}"] }

  # IDs never change when a repository or owner is renamed, and a new repository cannot reuse them.
  github_id_claims = { for k, v in {
    "token.actions.githubusercontent.com:repository_id"       = length(var.github_repository_ids) > 0 ? var.github_repository_ids : null
    "token.actions.githubusercontent.com:repository_owner_id" = jsondecode(length(var.github_owner_ids) > 0 ? jsonencode(distinct(var.github_owner_ids)) : jsonencode(var.github_owner_id))
  } : k => v if v != null }

  github_trust = { for name, r in local.github_roles : name => jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "GitHubActionsOidc"
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.oidc_arn }
      # StringLike appears only when a listed workflow ref holds a wildcard.
      Condition = { for op, claims in {
        StringEquals = merge(
          {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = local.role_subs[name]
          },
          local.github_id_claims,
          length(r.workflow_refs) > 0 && !anytrue([for w in r.workflow_refs : strcontains(w, "*")]) ? { "token.actions.githubusercontent.com:job_workflow_ref" = r.workflow_refs } : {},
        )
        StringLike = anytrue([for w in r.workflow_refs : strcontains(w, "*")]) ? { "token.actions.githubusercontent.com:job_workflow_ref" = r.workflow_refs } : {}
      } : op => claims if length(claims) > 0 }
    }]
  }) }

  # Azure DevOps: the same StringEquals on aud and on an exact sub per service connection. Plan roles trust the
  # plan connections; each apply role trusts only its environment's connections.
  ado_plan_subs = distinct([for c in var.ado_plan_service_connections : "sc://${coalesce(var.ado_organization_name, "none")}/${c.project}/${c.name}"])
  ado_role_subs = { for name, r in local.github_roles : name => (
    r.suffix == "pull_request" || startswith(r.suffix, "ref:") ? local.ado_plan_subs :
    distinct([for c in lookup(var.ado_apply_service_connections, trimprefix(r.suffix, "environment:"), []) : "sc://${coalesce(var.ado_organization_name, "none")}/${c.project}/${c.name}"])
  ) }
  ado_trust = { for name, subs in local.ado_role_subs : name => jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AzureDevOpsOidc"
      Effect    = "Allow"
      Action    = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.oidc_arn }
      Condition = {
        StringEquals = {
          "${local.issuer_host}:aud" = local.oidc_aud
          "${local.issuer_host}:sub" = subs
        }
      }
    }]
  }) }

  ci_trust = local.ado ? local.ado_trust : local.github_trust
  ci_subs  = local.ado ? local.ado_role_subs : local.role_subs

  # Explicit denies that keep plan roles away from application data, secrets and tokens.
  # A plan refreshes resource settings only; none of these reads is needed for it.
  data_plane_deny = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid         = "DataPlaneDenyObjectReads"
        Effect      = "Deny"
        Action      = ["s3:GetObject", "s3:GetObjectVersion"]
        NotResource = ["${local.bucket_arn}/*"]
      },
      {
        Sid    = "DataPlaneDenyItemReads"
        Effect = "Deny"
        Action = [
          "dynamodb:GetItem", "dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:Scan", "dynamodb:PartiQLSelect", "dynamodb:GetRecords",
          "sqs:ReceiveMessage", "states:DescribeExecution", "states:GetExecutionHistory", "states:GetActivityTask",
        ]
        Resource = "*"
      },
      {
        # Application logs, access logs (source IPs) and workflow inputs outside production.
        Sid      = "DataPlaneDenyLogEvents"
        Effect   = "Deny"
        Action   = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:GetQueryResults", "logs:StartLiveTail", "logs:GetLogRecord", "logs:Unmask"]
        Resource = "*"
      },
      {
        Sid      = "DataPlaneDenyApiKeyValues"
        Effect   = "Deny"
        Action   = "apigateway:GET"
        Resource = local.api_key_arns
      },
      {
        Sid      = "DataPlaneDenyInvoke"
        Effect   = "Deny"
        Action   = ["lambda:Invoke*"]
        Resource = "*"
      },
      {
        Sid      = "DataPlaneDenySecrets"
        Effect   = "Deny"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:BatchGetSecretValue"]
        Resource = "*"
      },
      {
        # Blocks SecureString parameters, secrets and every other key; only state reads through S3 decrypt.
        Sid       = "DataPlaneDenyDecryptOutsideState"
        Effect    = "Deny"
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*", "kms:ReEncrypt*"]
        Resource  = "*"
        Condition = { StringNotEquals = { "kms:ViaService" = local.s3_via } }
      },
      {
        # A plan never takes on another role, so a workload role that trusts a plan role gains nothing.
        Sid      = "DataPlaneDenyTokens"
        Effect   = "Deny"
        Action   = ["ecr:GetAuthorizationToken", "codeartifact:GetAuthorizationToken", "sts:GetServiceBearerToken", "sts:AssumeRole"]
        Resource = "*"
      },
    ]
  })

  # Roles that apply roles create must sit under /<path>/<env>/ and carry that environment's boundary.
  workload_iam = { for e in var.environments : e => jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "IamRead"
        Effect   = "Allow"
        Action   = ["iam:Get*", "iam:List*"]
        Resource = "*"
      },
      {
        Sid       = "BoundedWorkloadRoles"
        Effect    = "Allow"
        Action    = ["iam:CreateRole", "iam:PutRolePermissionsBoundary", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy"]
        Resource  = "${local.iam_prefix}:role/${var.service_role_path}/${e}/*"
        Condition = { StringEquals = { "iam:PermissionsBoundary" = local.boundary_arns[e] } }
      },
      {
        Sid      = "ManageWorkloadRoles"
        Effect   = "Allow"
        Action   = ["iam:DeleteRole", "iam:TagRole", "iam:UntagRole", "iam:UpdateRole", "iam:UpdateRoleDescription", "iam:UpdateAssumeRolePolicy"]
        Resource = "${local.iam_prefix}:role/${var.service_role_path}/${e}/*"
      },
      {
        Sid      = "ManageWorkloadPolicies"
        Effect   = "Allow"
        Action   = ["iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy"]
        Resource = "${local.iam_prefix}:policy/${var.service_role_path}/${e}/*"
      },
      {
        Sid       = "PassWorkloadRoles"
        Effect    = "Allow"
        Action    = "iam:PassRole"
        Resource  = "${local.iam_prefix}:role/${var.service_role_path}/${e}/*"
        Condition = { StringEquals = { "iam:PassedToService" = concat(["lambda.amazonaws.com", "states.amazonaws.com"], var.passrole_services) } }
      },
      {
        # An explicit deny, so a broader policy attached later still cannot create a role, or set
        # its trust, outside this environment's path. IAM has no condition key on trust policy
        # content, so the trust of the roles inside the path is reviewed in the plan (README).
        Sid         = "TrustOnlyOwnWorkloadRoles"
        Effect      = "Deny"
        Action      = ["iam:CreateRole", "iam:UpdateAssumeRolePolicy"]
        NotResource = "${local.iam_prefix}:role/${var.service_role_path}/${e}/*"
      },
    ]
  }) }

  # Single-account mode: the apply role of every environment outside var.production_environments,
  # and every role it creates (through that environment's boundary), is kept away from production.
  # The production environments are named explicitly, so isolation never depends on a literal name.
  production_deny_envs = var.account_mode == "single" ? toset([for e in local.ci_environments : e if !contains(var.production_environments, e)]) : toset([])
  # Resource names are <service>-<environment>-<purpose>; state keys are <service>/<environment>/terraform.tfstate.
  # IAM refuses a wildcard service in a resource ARN (MalformedPolicyDocument: "Resource vendor must be fully
  # qualified"), so each service whose ARN carries the name is listed. Resources addressed by ID only (API
  # Gateway, CloudFront) are covered by the tag denies, which every root's default_tags makes complete.
  production_name_arns = flatten([for p in var.production_environments : concat([
    for n in ["*-${p}-*", "*-${p}"] : [
      "arn:${local.partition}:s3:::${n}",
      "arn:${local.partition}:lambda:*:*:function:${n}",
      "arn:${local.partition}:iam::*:role/${n}",
      "arn:${local.partition}:secretsmanager:*:*:secret:${n}",
      "arn:${local.partition}:kms:*:*:alias/${n}",
      "arn:${local.partition}:dynamodb:*:*:table/${n}",
      "arn:${local.partition}:sqs:*:*:${n}",
      "arn:${local.partition}:sns:*:*:${n}",
      "arn:${local.partition}:states:*:*:stateMachine:${n}",
      "arn:${local.partition}:events:*:*:rule/${n}",
      "arn:${local.partition}:cloudwatch:*:*:alarm:${n}",
      "arn:${local.partition}:wafv2:*:*:*/webacl/${n}/*",
      "arn:${local.partition}:logs:*:*:log-group:${n}",
    ]
  ], ["arn:${local.partition}:logs:*:*:log-group:/aws/lambda/*-${p}-*"])])
  production_state_arns = [for p in var.production_environments : "${local.bucket_arn}/*/${p}/*"]
  production_deny_resources = [
    {
      Sid       = "ProductionDenyTaggedResources"
      Effect    = "Deny"
      Action    = "*"
      Resource  = "*"
      Condition = { StringEquals = { "aws:ResourceTag/environment" = var.production_environments } }
    },
    {
      Sid       = "ProductionDenyTaggedRequests"
      Effect    = "Deny"
      Action    = "*"
      Resource  = "*"
      Condition = { StringEquals = { "aws:RequestTag/environment" = var.production_environments } }
    },
    {
      Sid      = "ProductionDenyNamedResources"
      Effect   = "Deny"
      Action   = "*"
      Resource = local.production_name_arns
    },
    {
      Sid      = "ProductionDenyStateAndPlans"
      Effect   = "Deny"
      Action   = "s3:*"
      Resource = concat(local.production_state_arns, ["${local.bucket_arn}/plans/*"])
    },
  ]
  production_deny = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.production_deny_resources, [
      {
        Sid      = "ProductionDenyPassRole"
        Effect   = "Deny"
        Action   = "iam:PassRole"
        Resource = [for p in var.production_environments : "${local.iam_prefix}:role/${var.service_role_path}/${p}/*"]
      },
      {
        # Origin access controls and response headers policies take no tags, and their ARNs hold
        # an ID, not a name. So no non-production apply role may change or delete any of them.
        Sid    = "ProductionDenyUntaggedEdgeSettings"
        Effect = "Deny"
        Action = [
          "cloudfront:UpdateOriginAccessControl", "cloudfront:DeleteOriginAccessControl",
          "cloudfront:UpdateResponseHeadersPolicy", "cloudfront:DeleteResponseHeadersPolicy",
        ]
        Resource = "*"
      },
    ])
  })

  # Deny statements that keep the account's security baseline (modules/security-baseline) as its owner left it,
  # whatever a workload role's own policy allows. Left out with protect_security_baseline = false.
  security_baseline_denies = [
    {
      # The account's security baseline (modules/security-baseline): its alerts topic and email
      # subscription, its findings rules and its trail log group stay as the person who applied it
      # left them, whatever a workload role's own policy allows. The names follow
      # security_baseline_prefix. Every SNS and EventBridge action on the topic and the rules
      # except reading them: only those services' actions name these resources, so the deny reaches
      # nothing else. Publishing is denied too; the alarms and rules publish as AWS services, which a
      # boundary does not bind.
      Sid       = "ProtectSecurityBaseline"
      Effect    = "Deny"
      NotAction = ["sns:Get*", "sns:List*", "events:Describe*", "events:List*"]
      Resource = [
        "arn:${local.partition}:sns:*:${var.account_id}:${var.security_baseline_prefix}-*",
        "arn:${local.partition}:events:*:${var.account_id}:rule/${var.security_baseline_prefix}-*",
      ]
    },
    {
      # The default event bus the security baseline's protection policy keeps the apply roles off:
      # neither can a workload role re-point or re-key it. Region * because the bus is account-wide.
      Sid    = "ProtectDefaultEventBus"
      Effect = "Deny"
      Action = "events:UpdateEventBus"
      Resource = [
        "arn:${local.partition}:events:*:${var.account_id}:event-bus/default",
        "arn:${local.partition}:events:*:${var.account_id}:event-busv2/default/*",
      ]
    },
    {
      # Every logs action on the trail log group and its streams except reading and querying the
      # events. IAM compares Resource with the resource a request names, and only CloudWatch Logs
      # actions name a log group, so this deny reaches no other service, nor a logs action that
      # names no resource. Reading the events is still open. The log-group resource policy is an
      # accepted risk, not an open route: logs:PutResourcePolicy names no resource in IAM and lets
      # only an AWS service write events into a group.
      Sid    = "ProtectSecurityBaselineLogs"
      Effect = "Deny"
      NotAction = [
        "logs:Get*", "logs:Describe*", "logs:List*", "logs:FilterLogEvents", "logs:StartQuery", "logs:StopQuery",
        "logs:GetQueryResults", "logs:StartLiveTail", "logs:StopLiveTail",
      ]
      Resource = [
        "arn:${local.partition}:logs:*:${var.account_id}:log-group:${var.security_baseline_prefix}-*",
        "arn:${local.partition}:logs:*:${var.account_id}:log-group:${var.security_baseline_prefix}-*:*",
      ]
    },
    {
      # Account-level logs policies reach that log group without naming it: a data protection policy
      # masks what its metric filters see, a transformer reshapes the events they match, and a
      # subscription filter policy copies the events out.
      Sid      = "ProtectLogsAccountPolicies"
      Effect   = "Deny"
      Action   = ["logs:PutAccountPolicy", "logs:DeleteAccountPolicy"]
      Resource = "*"
    },
    {
      # The account-wide S3 public access block, which s3:* above would otherwise let a workload role
      # switch off; turning it off, or deleting it, is this one action.
      Sid      = "ProtectAccountPublicAccessBlock"
      Effect   = "Deny"
      Action   = "s3:PutAccountPublicAccessBlock"
      Resource = "*"
    },
    {
      # Its alarms read metrics in this namespace; PutMetricData names no resource.
      Sid       = "ProtectSecurityBaselineMetrics"
      Effect    = "Deny"
      Action    = "cloudwatch:PutMetricData"
      Resource  = "*"
      Condition = { StringEquals = { "cloudwatch:namespace" = "SecurityBaseline" } }
    },
  ]

  # Upper limit for workload roles. Outside production_environments in a single account it also
  # carries the production denies, so a role created for dev cannot reach production data or secrets.
  workload_boundary = { for e in local.ci_environments : e => jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid    = "WorkloadServices"
        Effect = "Allow"
        Action = [
          "logs:*", "xray:*", "cloudwatch:PutMetricData", "dynamodb:*", "s3:*", "sqs:*", "sns:*", "events:*", "states:*",
          "lambda:InvokeFunction", "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey",
          "secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "ssm:GetParameter*", "execute-api:Invoke",
          "ecr:GetAuthorizationToken", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability",
          "ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface",
          "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses",
        ]
        Resource = "*"
      },
      {
        Sid      = "NoStateAccess"
        Effect   = "Deny"
        Action   = "s3:*"
        Resource = [local.bucket_arn, "${local.bucket_arn}/*"]
      },
      ],
      [for s in local.security_baseline_denies : s if var.protect_security_baseline],
      length(lookup(var.workload_boundary_extra_actions, e, [])) > 0 ? [{
        Sid      = "WorkloadExtraReads"
        Effect   = "Allow"
        Action   = var.workload_boundary_extra_actions[e]
        Resource = "*"
      }] : [],
    [for s in local.production_deny_resources : s if contains(local.production_deny_envs, e)])
  }) }
}

# ------------------------------------------------------------------ state key and bucket

locals {
  # null when create_state_kms_key is false: the bucket then uses SSE-S3 and no policy names a key.
  state_key_arn = one(aws_kms_key.state[*].arn)
}

# A bootstrap applied before create_state_kms_key existed keeps its key: same key, new address.
moved {
  from = aws_kms_key.state
  to   = aws_kms_key.state[0]
}

moved {
  from = aws_kms_alias.state
  to   = aws_kms_alias.state[0]
}

resource "aws_kms_key" "state" {
  count                   = var.create_state_kms_key ? 1 : 0
  description             = "Encrypts Terraform state and saved plans in ${local.bucket_name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.tags
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountAdministersKeyThroughIam"
      Effect    = "Allow"
      Principal = { AWS = "${local.iam_prefix}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })

  lifecycle {
    prevent_destroy = true

    # The plan stops before any change when the provider points at another account or Region.
    precondition {
      condition     = data.aws_caller_identity.current.account_id == var.account_id
      error_message = "The aws provider's credentials are for account ${data.aws_caller_identity.current.account_id}, not account_id ${var.account_id}. Use a profile for the account this bootstrap belongs to."
    }

    precondition {
      condition     = data.aws_region.current.region == var.region
      error_message = "The aws provider is set to Region ${data.aws_region.current.region}, not region ${var.region}. Set the provider's region to the same value."
    }
  }
}

resource "aws_kms_alias" "state" {
  count         = var.create_state_kms_key ? 1 : 0
  name          = "alias/${local.name_base}-shared-tfstate"
  target_key_id = aws_kms_key.state[0].key_id
}

resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_18:state is read only by the CI roles and the automation identity, whose calls CloudTrail records
  # checkov:skip=CKV_AWS_144:there is no second Region by design; versioning and prevent_destroy protect state
  # checkov:skip=CKV2_AWS_62:nothing consumes object events from the state bucket
  bucket = local.bucket_name
  tags   = local.tags

  lifecycle {
    prevent_destroy = true

    # The same guards as on the key, so they hold when create_state_kms_key is false.
    precondition {
      condition     = var.create_state_kms_key || data.aws_caller_identity.current.account_id == var.account_id
      error_message = "The aws provider's credentials are for account ${data.aws_caller_identity.current.account_id}, not account_id ${var.account_id}. Use a profile for the account this bootstrap belongs to."
    }

    precondition {
      condition     = var.create_state_kms_key || data.aws_region.current.region == var.region
      error_message = "The aws provider is set to Region ${data.aws_region.current.region}, not region ${var.region}. Set the provider's region to the same value."
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.create_state_kms_key ? "aws:kms" : "AES256"
      kms_master_key_id = local.state_key_arn
    }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyOldTls"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { NumericLessThan = { "s3:TlsVersion" = "1.2" } }
      },
      ], var.create_state_kms_key ? [
      {
        # An upload that names any encryption must name SSE-KMS with the state key: these three
        # statements refuse another algorithm, aws:kms without a key ID (S3 would use aws/s3),
        # and any other key. Uploads that name none get the bucket default, the state key.
        Sid       = "DenyNonKmsUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/*"
        Condition = {
          StringNotEquals = { "s3:x-amz-server-side-encryption" = "aws:kms" }
          Null            = { "s3:x-amz-server-side-encryption" = "false" }
        }
      },
      {
        Sid       = "DenyKmsWithoutStateKey"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/*"
        Condition = {
          Null = {
            "s3:x-amz-server-side-encryption"                = "false"
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = "true"
          }
        }
      },
      {
        Sid       = "DenyOtherKmsKeys"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/*"
        Condition = {
          StringNotEquals = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = local.state_key_arn }
          Null            = { "s3:x-amz-server-side-encryption-aws-kms-key-id" = "false" }
        }
      },
      ] : [
      {
        # Key off: the bucket default is SSE-S3 and an upload that names no encryption gets it. A role with
        # PowerUserAccess must not choose another way, so an upload that names an algorithm must name
        # AES256, and one that supplies its own key (SSE-C) is refused. The header is never required.
        Sid       = "DenyNonSseS3Uploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/*"
        Condition = {
          StringNotEquals = { "s3:x-amz-server-side-encryption" = "AES256" }
          Null            = { "s3:x-amz-server-side-encryption" = "false" }
        }
      },
      {
        Sid       = "DenySseCUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${local.bucket_arn}/*"
        Condition = { Null = { "s3:x-amz-server-side-encryption-customer-algorithm" = "false" } }
      },
      ], [
      {
        # The same bucket settings that FoundationProtect denies the apply roles, denied here to every
        # GitHub role and workload role as well, whatever their own policies say later.
        Sid       = "DenyBucketSettingsToPipelineRoles"
        Effect    = "Deny"
        Principal = "*"
        Action    = local.state_bucket_settings
        Resource  = local.bucket_arn
        Condition = { ArnLike = { "aws:PrincipalArn" = [local.delivery_role_arns, local.workload_role_arns] } }
      },
    ])
  })

  depends_on = [aws_s3_bucket_public_access_block.state]
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  # Saved plans hold sensitive values; they live plans_expiration_days (default 7), long enough for release approval.
  rule {
    id     = "plans-expire"
    status = "Enabled"
    filter {
      prefix = "plans/"
    }
    expiration {
      days = var.plans_expiration_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }

  rule {
    id     = "state-history"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
    expiration {
      expired_object_delete_marker = true
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_upload_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.state]
}

# ------------------------------------------------------------------ GitHub OIDC and roles

# One per account. A second tenant in the same account sets create_oidc_provider = false;
# with ci_roles = false there is none.
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.ci_roles && var.create_oidc_provider ? 1 : 0
  url            = "https://${local.issuer_host}"
  client_id_list = [local.oidc_aud]

  # The argument thumbprint_list is left out: AWS supplies the thumbprint for GitHub's issuer, and IAM retrieves
  # it for Azure DevOps's, so plans stay clean.

  tags = local.tags
}

resource "aws_iam_role" "plan" {
  for_each             = local.plan_roles
  name                 = each.value.name
  description          = "Read-only Terraform plans from ${join(", ", local.ci_subs[each.value.name])}"
  assume_role_policy   = local.ci_trust[each.value.name]
  max_session_duration = var.max_session_duration
  tags                 = local.tags

  depends_on = [aws_iam_openid_connect_provider.github]
}

resource "aws_iam_role_policy_attachment" "plan_read_only" {
  for_each   = aws_iam_role.plan
  role       = each.value.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_data_plane_deny" {
  for_each = aws_iam_role.plan
  name     = "DataPlaneDeny"
  role     = each.value.name
  policy   = local.data_plane_deny
}

# Plans run with -lock=false, so neither plan role writes a lock file. <prefix>-plan-pr writes
# nothing at all and cannot read production state: production is planned only after merge,
# by <prefix>-plan-default, which may add saved plans under plans/ encrypted with the state key.
resource "aws_iam_role_policy" "plan_state" {
  for_each = aws_iam_role.plan
  name     = "StateRead"
  role     = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        { Sid = "StateList", Effect = "Allow", Action = "s3:ListBucket", Resource = local.bucket_arn },
        { Sid = "StateRead", Effect = "Allow", Action = "s3:GetObject", Resource = "${local.bucket_arn}/*" },
      ],
      [for s in [
        {
          Sid       = "StateKeyThroughS3"
          Effect    = "Allow"
          Action    = each.key == "default" ? ["kms:Decrypt", "kms:GenerateDataKey"] : ["kms:Decrypt"]
          Resource  = local.state_key_arn
          Condition = { StringEquals = { "kms:ViaService" = local.s3_via } }
        },
      ] : s if var.create_state_kms_key],
      [for s in [
        merge({
          Sid      = "SavePlans"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${local.bucket_arn}/plans/*"
          }, var.create_state_kms_key ? {
          Condition = { StringEquals = {
            "s3:x-amz-server-side-encryption"                = "aws:kms"
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = local.state_key_arn
          } }
          } : {
          Condition = {
            StringEqualsIfExists = { "s3:x-amz-server-side-encryption" = "AES256" }
            Null                 = { "s3:x-amz-server-side-encryption-customer-algorithm" = "true" }
          }
        }),
      ] : s if each.key == "default"],
      [for s in [
        { Sid = "PlansNotReadable", Effect = "Deny", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = "${local.bucket_arn}/plans/*" },
        { Sid = "ProductionStateNotReadable", Effect = "Deny", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = local.production_state_arns },
      ] : s if each.key != "default" && (s.Sid != "ProductionStateNotReadable" || length(local.production_state_arns) > 0)]
    )
  })
}

resource "aws_iam_policy" "workload_boundary" {
  # checkov:skip=CKV_AWS_288:a permissions boundary is a ceiling; each workload role's own policy grants the narrow actions
  # checkov:skip=CKV_AWS_289:a permissions boundary is a ceiling; each workload role's own policy grants the narrow actions
  # checkov:skip=CKV_AWS_290:a permissions boundary is a ceiling; each workload role's own policy grants the narrow actions
  # checkov:skip=CKV_AWS_355:a permissions boundary is a ceiling; each workload role's own policy grants the narrow actions
  for_each    = local.workload_boundary
  name        = "${local.name_base}-${each.key}-workload-boundary"
  description = "Upper limit for ${each.key} workload roles that the apply roles create"
  policy      = each.value
  tags        = local.tags
}

resource "aws_iam_role" "apply" {
  for_each             = local.ci_environments
  name                 = "${var.name_prefix}-apply-${each.key}"
  description          = "Terraform apply for ${each.key}, only from ${local.ado ? "its Azure DevOps service connections" : "the GitHub Environment ${each.key}"}"
  assume_role_policy   = local.ci_trust["${var.name_prefix}-apply-${each.key}"]
  max_session_duration = var.max_session_duration
  tags                 = local.tags

  depends_on = [aws_iam_openid_connect_provider.github]
}

# PowerUserAccess unless apply_policy_arns names others; the inline denies below apply either way.
resource "aws_iam_role_policy_attachment" "apply_policies" {
  for_each = { for pair in setproduct(local.ci_environments, local.apply_policy_arns) : "${pair[0]}|${pair[1]}" => {
    role = aws_iam_role.apply[pair[0]].name, policy_arn = pair[1]
  } }
  role       = each.value.role
  policy_arn = each.value.policy_arn
}

resource "aws_iam_role_policy" "apply_workload_iam" {
  for_each = aws_iam_role.apply
  name     = "WorkloadIam"
  role     = each.value.name
  policy   = local.workload_iam[each.key]
}

resource "aws_iam_role_policy" "apply_state" {
  for_each = aws_iam_role.apply
  name     = "StateReadWrite"
  role     = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        { Sid = "StateList", Effect = "Allow", Action = "s3:ListBucket", Resource = local.bucket_arn },
        { Sid = "StateReadWrite", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${local.bucket_arn}/*" },
        {
          Sid      = "SavedPlansReadOnly"
          Effect   = "Deny"
          Action   = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutObjectVersionTagging"]
          Resource = "${local.bucket_arn}/plans/*"
        },
      ],
      [for s in [
        {
          Sid       = "StateKeyThroughS3"
          Effect    = "Allow"
          Action    = ["kms:Decrypt", "kms:GenerateDataKey"]
          Resource  = local.state_key_arn
          Condition = { StringEquals = { "kms:ViaService" = local.s3_via } }
        },
      ] : s if var.create_state_kms_key],
      # Only the apply roles of production_environments read saved plans.
      [for s in [
        { Sid = "SavedPlansProductionOnly", Effect = "Deny", Action = ["s3:GetObject", "s3:GetObjectVersion"], Resource = "${local.bucket_arn}/plans/*" },
      ] : s if !contains(var.production_environments, each.key)]
    )
  })
}

resource "aws_iam_role_policy" "apply_foundation_protect" {
  for_each = aws_iam_role.apply
  name     = "FoundationProtect"
  role     = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [for s in [
      {
        Sid      = "ProtectDeliveryIdentity"
        Effect   = "Deny"
        Action   = "iam:*"
        Resource = concat([local.delivery_role_arns, local.oidc_arn], values(local.boundary_arns))
      },
      {
        Sid      = "KeepBoundaries"
        Effect   = "Deny"
        Action   = "iam:DeleteRolePermissionsBoundary"
        Resource = "*"
      },
      {
        # Workload roles are for AWS services only; an apply role never takes one on itself.
        Sid      = "NoAssumeWorkloadRoles"
        Effect   = "Deny"
        Action   = ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
        Resource = local.workload_role_arns
      },
      {
        Sid      = "ProtectStateBucket"
        Effect   = "Deny"
        Action   = local.state_bucket_settings
        Resource = local.bucket_arn
      },
      {
        # The bootstrap's own state, and its history, change only through the person who applies the bootstrap.
        Sid      = "ProtectBootstrapState"
        Effect   = "Deny"
        Action   = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutObjectVersionTagging"]
        Resource = "${local.bucket_arn}/bootstrap/*"
      },
      {
        # Grants too: S3 uses the key with the caller's own rights and needs no grant.
        Sid    = "ProtectStateKey"
        Effect = "Deny"
        Action = [
          "kms:ScheduleKeyDeletion", "kms:DisableKey", "kms:DisableKeyRotation", "kms:PutKeyPolicy", "kms:DeleteAlias", "kms:UpdateAlias",
          "kms:CreateGrant", "kms:RetireGrant", "kms:RevokeGrant", "kms:EnableKeyRotation", "kms:RotateKeyOnDemand",
        ]
        Resource = [local.state_key_arn, "arn:${local.partition}:kms:${var.region}:${var.account_id}:${try(aws_kms_alias.state[0].name, "alias/unused")}"]
      },
      {
        # The state key works only through S3 in this Region, as it does for the plan roles.
        Sid       = "StateKeyOnlyThroughS3"
        Effect    = "Deny"
        Action    = ["kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"]
        Resource  = local.state_key_arn
        Condition = { StringNotEquals = { "kms:ViaService" = local.s3_via } }
      },
      {
        Sid      = "ProtectBudget"
        Effect   = "Deny"
        Action   = ["budgets:ModifyBudget", "budgets:DeleteBudgetAction", "budgets:UpdateBudgetAction"]
        Resource = "arn:${local.partition}:budgets::${var.account_id}:budget/${local.budget_name}"
      },
    ] : s if var.create_state_kms_key || !contains(["ProtectStateKey", "StateKeyOnlyThroughS3"], try(s.Sid, ""))]
  })
}

resource "aws_iam_role_policy" "apply_production_deny" {
  for_each = local.production_deny_envs
  name     = "ProductionDeny"
  role     = aws_iam_role.apply[each.key].name
  policy   = local.production_deny
}

# ------------------------------------------------------------------ budget

resource "aws_budgets_budget" "account" {
  name         = local.budget_name
  budget_type  = "COST"
  limit_amount = format("%.2f", var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Credits are left out, so spend a credit pays for still reaches the budget owner.
  cost_types {
    include_credit = false
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.notification_email]
  }

  # Early warning: the month's forecast passes the limit before the cost does.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.notification_email]
  }

  tags = local.tags
}

# ------------------------------------------------------------------ REST API logging (on by default)
# API Gateway refuses REST API access and execution logs until the account has this role, and
# the plugin's rest-api example looks it up by the name suffix -shared-apigateway-logs.

resource "aws_iam_role" "api_gateway_logs" {
  count                = var.enable_api_gateway_account ? 1 : 0
  name                 = "${local.name_base}-shared-apigateway-logs"
  description          = "Lets API Gateway write REST API execution logs in ${var.region}"
  max_session_duration = var.max_session_duration
  tags                 = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "apigateway.amazonaws.com" }
      Condition = { StringEquals = { "aws:SourceAccount" = var.account_id } }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "api_gateway_logs" {
  count      = var.enable_api_gateway_account ? 1 : 0
  role       = aws_iam_role.api_gateway_logs[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  count               = var.enable_api_gateway_account ? 1 : 0
  cloudwatch_role_arn = aws_iam_role.api_gateway_logs[0].arn

  depends_on = [aws_iam_role_policy_attachment.api_gateway_logs]
}

# ------------------------------------------------------------------ container image registries

# One image registry per name, account-level: the image is built once and promoted by digest, so no environment owns it.
resource "aws_ecr_repository" "container" {
  # checkov:skip=CKV_AWS_136:0072: images hold no secrets; provider-managed AES256 avoids a key's monthly cost, the same choice as the kit's registry
  for_each = toset(var.container_repositories)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = local.tags
}

# Only untagged images beyond the newest 20 expire; a tagged image (pinned by digest) is never removed.
resource "aws_ecr_lifecycle_policy" "container" {
  for_each = aws_ecr_repository.container

  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images beyond the newest 20"
      selection    = { tagStatus = "untagged", countType = "imageCountMoreThan", countNumber = 20 }
      action       = { type = "expire" }
    }]
  })
}

# Lambda functions in this account and Region may pull the image (AWS's documented cross-service form).
resource "aws_ecr_repository_policy" "container" {
  for_each = aws_ecr_repository.container

  repository = each.value.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "LambdaPull"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Condition = { StringLike = { "aws:sourceArn" = "arn:${local.partition}:lambda:${var.region}:${var.account_id}:function:*" } }
    }]
  })
}
