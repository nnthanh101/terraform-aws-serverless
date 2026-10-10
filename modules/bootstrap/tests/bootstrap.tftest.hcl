# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Derived from the terraform-aws plugin's bootstrap template. See NOTICE.txt.
# Tier 1: plan-only tests with a mocked AWS provider: no credentials, no real resources.
# The 23 runs of the template, ported to the module's inputs; tenant features are in tenants.tftest.hcl.
mock_provider "aws" {
  override_data {
    target = data.aws_partition.current
    values = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      region = "ap-southeast-2"
    }
  }

  override_resource {
    target          = aws_kms_key.state
    override_during = plan
    values = {
      arn    = "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  account_id          = "123456789012"
  region              = "ap-southeast-2"
  github_repositories = ["acme/platform"]
  default_branch      = "develop"
  state_bucket_name   = "acme-shared-tfstate-123456789012"
  budget_limit_usd    = 250
  notification_email  = "finance@example.com"
  change_id           = "0001"
}

run "github_trusts_use_string_equals" {
  command = plan

  assert {
    condition = alltrue([
      for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) : alltrue([
        for s in jsondecode(r.assume_role_policy).Statement :
        join(",", keys(s.Condition)) == "StringEquals" && s.Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
      ])
    ])
    error_message = "Every GitHub trust must use StringEquals only, with aud sts.amazonaws.com."
  }

  assert {
    condition = alltrue([
      for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) : alltrue([
        for s in jsondecode(r.assume_role_policy).Statement :
        s.Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      ])
    ])
    error_message = "The federated principal must be the string built from account_id, so trust is known at plan time."
  }
}

run "no_wildcard_subs" {
  command = plan

  assert {
    condition = alltrue([
      for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) : alltrue([
        for s in jsondecode(r.assume_role_policy).Statement : alltrue([
          for sub in s.Condition.StringEquals["token.actions.githubusercontent.com:sub"] : !strcontains(sub, "*") && !strcontains(sub, "?")
        ])
      ])
    ])
    error_message = "No GitHub sub may contain a wildcard."
  }
}

run "apply_roles_trust_only_their_environment" {
  command = plan

  assert {
    condition     = join(",", sort(keys(aws_iam_role.apply))) == "dev,production"
    error_message = "One apply role per environment is expected."
  }

  assert {
    condition = alltrue([
      for e, r in aws_iam_role.apply :
      r.name == "gha-apply-${e}" && jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:acme/platform:environment:${e}"]
    ])
    error_message = "Apply roles must trust exactly repo:<org>/<repo>:environment:<env>."
  }
}

run "plan_roles_names_and_subs" {
  command = plan

  assert {
    condition     = aws_iam_role.plan["pr"].name == "gha-plan-pr" && aws_iam_role.plan["default"].name == "gha-plan-default"
    error_message = "Plan roles must be named gha-plan-pr and gha-plan-default."
  }

  assert {
    condition     = jsondecode(aws_iam_role.plan["pr"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:acme/platform:pull_request"]
    error_message = "gha-plan-pr must trust exactly repo:acme/platform:pull_request."
  }

  assert {
    condition     = jsondecode(aws_iam_role.plan["default"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:acme/platform:ref:refs/heads/develop"]
    error_message = "gha-plan-default must trust exactly the default branch from var.default_branch."
  }

  assert {
    condition     = alltrue([for a in values(aws_iam_role_policy_attachment.plan_read_only) : a.policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"])
    error_message = "Plan roles carry only the ReadOnlyAccess managed policy."
  }
}

run "plan_roles_carry_data_plane_deny" {
  command = plan

  assert {
    condition     = alltrue([for k in ["pr", "default"] : aws_iam_role_policy.plan_data_plane_deny[k].name == "DataPlaneDeny"])
    error_message = "Both plan roles need the DataPlaneDeny policy."
  }

  assert {
    condition = alltrue([
      for a in [
        "s3:GetObject", "dynamodb:Scan", "dynamodb:Query", "lambda:Invoke*", "secretsmanager:GetSecretValue", "kms:Decrypt",
        "logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery", "logs:StartLiveTail", "states:GetExecutionHistory",
        "states:DescribeExecution", "apigateway:GET", "sts:AssumeRole",
      ] :
      contains(flatten([for s in jsondecode(aws_iam_role_policy.plan_data_plane_deny["pr"].policy).Statement : s.Action if s.Effect == "Deny"]), a)
    ])
    error_message = "DataPlaneDeny must deny object, item, execution, log, API key, invoke, secret, decrypt and role reads."
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.plan_data_plane_deny["pr"].policy).Statement : s.Resource if s.Sid == "DataPlaneDenyApiKeyValues"
      ])) == toset([
      "arn:aws:apigateway:*::/apikeys", "arn:aws:apigateway:*::/apikeys/*",
      "arn:aws:apigateway:*::/usageplans/*/keys", "arn:aws:apigateway:*::/usageplans/*/keys/*",
    ])
    error_message = "Plan roles must not read API key values."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.plan_state["default"].policy).Statement : s
      if s.Sid == "SavePlans" && s.Effect == "Allow" && s.Resource == "arn:aws:s3:::acme-shared-tfstate-123456789012/plans/*" &&
      s.Condition.StringEquals["s3:x-amz-server-side-encryption"] == "aws:kms" &&
      s.Condition.StringEquals["s3:x-amz-server-side-encryption-aws-kms-key-id"] == "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
    ]) == 1
    error_message = "gha-plan-default may write only saved plans under plans/, encrypted with the state key."
  }

  assert {
    condition = alltrue([for k in ["pr", "default"] : length([
      for s in jsondecode(aws_iam_role_policy.plan_state[k].policy).Statement : s
      if s.Effect == "Allow" && length(setintersection(toset(flatten([s.Action])), toset(["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]))) > 0 && s.Sid != "SavePlans"
    ]) == 0])
    error_message = "Plans run with -lock=false: neither plan role may write or delete lock files or state."
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.plan_state["pr"].policy).Statement : s if s.Effect == "Allow" && contains(flatten([s.Action]), "s3:PutObject")]) == 0
    error_message = "gha-plan-pr may write nothing."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_iam_role_policy.plan_state["pr"].policy).Statement : s
      if s.Effect == "Deny" && contains(flatten([s.Action]), "s3:GetObject") && join(",", flatten([s.Resource])) == "arn:aws:s3:::acme-shared-tfstate-123456789012/*/production/*"
    ]) == 1
    error_message = "gha-plan-pr must not read production state; production is planned after merge by gha-plan-default."
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.plan_state["default"].policy).Statement : s if s.Sid == "ProductionStateNotReadable"]) == 0
    error_message = "gha-plan-default plans production, so it must read production state."
  }
}

run "apply_roles_pass_only_listed_services" {
  command = plan

  assert {
    condition = alltrue([
      for e in ["dev", "production"] : join("|", [
        for s in jsondecode(aws_iam_role_policy.apply_workload_iam[e].policy).Statement :
        join(",", sort(s.Condition.StringEquals["iam:PassedToService"])) if contains(flatten([s.Action]), "iam:PassRole")
      ]) == "lambda.amazonaws.com,states.amazonaws.com"
    ])
    error_message = "Exactly one statement may grant iam:PassRole, limited to lambda.amazonaws.com and states.amazonaws.com."
  }

  assert {
    condition = alltrue([
      for e in ["dev", "production"] : join("|", [
        for s in jsondecode(aws_iam_role_policy.apply_workload_iam[e].policy).Statement :
        s.Condition.StringEquals["iam:PermissionsBoundary"] if s.Effect == "Allow" && contains(flatten([s.Action]), "iam:CreateRole")
      ]) == "arn:aws:iam::123456789012:policy/platform-${e}-workload-boundary"
    ])
    error_message = "Workload roles may be created only with their own environment's boundary."
  }

  assert {
    condition = alltrue([
      for e in ["dev", "production"] : length([
        for s in jsondecode(aws_iam_role_policy.apply_foundation_protect[e].policy).Statement : s
        if s.Sid == "NoAssumeWorkloadRoles" && s.Effect == "Deny" && contains(flatten([s.Action]), "sts:AssumeRole") && s.Resource == "arn:aws:iam::123456789012:role/workload/*"
      ]) == 1
    ])
    error_message = "Apply roles must not assume the workload roles they create."
  }

  assert {
    condition = alltrue([
      for e in ["dev", "production"] : length(setsubtract(
        toset(["arn:aws:iam::123456789012:policy/platform-dev-workload-boundary", "arn:aws:iam::123456789012:policy/platform-production-workload-boundary"]),
        toset(flatten([for s in jsondecode(aws_iam_role_policy.apply_foundation_protect[e].policy).Statement : s.Resource if s.Sid == "ProtectDeliveryIdentity"]))
      )) == 0
    ])
    error_message = "Apply roles must not change any workload boundary."
  }
}

run "one_boundary_per_environment" {
  command = plan

  assert {
    condition     = join(",", sort([for p in values(aws_iam_policy.workload_boundary) : p.name])) == "platform-dev-workload-boundary,platform-production-workload-boundary"
    error_message = "Each environment needs its own workload boundary, named <service>-<environment>-workload-boundary."
  }

  assert {
    condition = alltrue([
      for sid in ["ProductionDenyTaggedResources", "ProductionDenyTaggedRequests", "ProductionDenyNamedResources", "ProductionDenyStateAndPlans"] :
      contains([for s in jsondecode(aws_iam_policy.workload_boundary["dev"].policy).Statement : s.Sid if s.Effect == "Deny"], sid)
    ])
    error_message = "In a single account the dev boundary must carry the production denies, so roles created for dev cannot reach production."
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.workload_boundary["production"].policy).Statement : s if startswith(s.Sid, "ProductionDeny")]) == 0
    error_message = "The production boundary must not deny production."
  }

  assert {
    condition     = alltrue([for p in values(aws_iam_policy.workload_boundary) : length(p.policy) < 6144])
    error_message = "Each boundary must fit the 6,144-character managed policy limit."
  }
}

run "single_account_production_deny" {
  command = plan

  assert {
    condition     = join(",", keys(aws_iam_role_policy.apply_production_deny)) == "dev" && aws_iam_role_policy.apply_production_deny["dev"].role == "gha-apply-dev"
    error_message = "In single-account mode gha-apply-dev must carry ProductionDeny, and gha-apply-production must not."
  }

  assert {
    condition     = contains([for s in jsondecode(aws_iam_role_policy.apply_production_deny["dev"].policy).Statement : s.Sid], "ProductionDenyTaggedResources")
    error_message = "ProductionDeny must deny resources tagged environment=production."
  }

  assert {
    condition = toset(flatten([
      for s in jsondecode(aws_iam_role_policy.apply_production_deny["dev"].policy).Statement : s.Action if s.Sid == "ProductionDenyUntaggedEdgeSettings"
      ])) == toset([
      "cloudfront:UpdateOriginAccessControl", "cloudfront:DeleteOriginAccessControl",
      "cloudfront:UpdateResponseHeadersPolicy", "cloudfront:DeleteResponseHeadersPolicy",
    ])
    error_message = "gha-apply-dev must not change origin access controls or response headers policies, which carry no tags."
  }

  assert {
    condition = length(join("", [
      aws_iam_role_policy.apply_workload_iam["dev"].policy, aws_iam_role_policy.apply_state["dev"].policy,
      aws_iam_role_policy.apply_foundation_protect["dev"].policy, aws_iam_role_policy.apply_production_deny["dev"].policy,
    ])) < 10240
    error_message = "The inline policies of gha-apply-dev must fit the 10,240-character limit for one role."
  }

  assert {
    condition     = length(join("", [aws_iam_role_policy.plan_data_plane_deny["default"].policy, aws_iam_role_policy.plan_state["default"].policy])) < 10240
    error_message = "The inline policies of gha-plan-default must fit the 10,240-character limit for one role."
  }
}

run "landing_zone_has_no_production_deny" {
  command = plan

  variables {
    account_mode = "landing-zone"
    environments = ["production"]
  }

  assert {
    condition     = length(aws_iam_role_policy.apply_production_deny) == 0
    error_message = "One account per environment needs no ProductionDeny."
  }

  assert {
    condition     = keys(aws_iam_policy.workload_boundary) == ["production"] && length([for s in jsondecode(aws_iam_policy.workload_boundary["production"].policy).Statement : s if startswith(s.Sid, "ProductionDeny")]) == 0
    error_message = "A production-only account has one boundary, with no production denies."
  }
}

run "single_account_production_named_prod" {
  command = plan

  variables {
    account_mode            = "single"
    environments            = ["dev", "prod"]
    production_environments = ["prod"]
  }

  assert {
    condition     = join(",", keys(aws_iam_role_policy.apply_production_deny)) == "dev" && aws_iam_role_policy.apply_production_deny["dev"].role == "gha-apply-dev"
    error_message = "With production named prod, gha-apply-dev must still carry ProductionDeny, and gha-apply-prod must not."
  }

  assert {
    condition = alltrue([
      for sid in ["ProductionDenyTaggedResources", "ProductionDenyTaggedRequests", "ProductionDenyNamedResources", "ProductionDenyStateAndPlans"] :
      contains([for s in jsondecode(aws_iam_policy.workload_boundary["dev"].policy).Statement : s.Sid if s.Effect == "Deny"], sid)
    ])
    error_message = "With production named prod, the dev boundary must still carry the production denies."
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.workload_boundary["prod"].policy).Statement : s if startswith(s.Sid, "ProductionDeny")]) == 0
    error_message = "The prod boundary must not deny prod."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.apply_production_deny["dev"].policy).Statement :
      join(",", s.Condition.StringEquals[keys(s.Condition.StringEquals)[0]]) == "prod" if startswith(s.Sid, "ProductionDenyTagged")
    ])
    error_message = "The tag denies must name the tag value of the production environment, prod."
  }

  assert {
    condition = alltrue([
      for arn in [
        "arn:aws:lambda:*:*:function:*-prod-*", "arn:aws:iam::*:role/*-prod-*", "arn:aws:s3:::*-prod-*", "arn:aws:logs:*:*:log-group:/aws/lambda/*-prod-*",
      ] : contains(flatten([for s in jsondecode(aws_iam_policy.workload_boundary["dev"].policy).Statement : s.Resource if s.Sid == "ProductionDenyNamedResources"]), arn)
    ])
    error_message = "The name denies must cover <service>-prod-<purpose> resources, buckets and function log groups."
  }

  # IAM refuses a policy whose resource ARN has no service ("Resource vendor must be fully qualified"); a mocked
  # plan cannot see that, so the shape is asserted here for every policy this module writes.
  assert {
    condition = alltrue(flatten([
      for doc in concat([for k, p in aws_iam_policy.workload_boundary : p.policy], [for k, p in aws_iam_role_policy.apply_production_deny : p.policy]) : [
        for s in jsondecode(doc).Statement : [
          for r in flatten([try(s.Resource, []), try(s.NotResource, [])]) : r == "*" || can(regex("^arn:[a-z-]+:[a-z0-9-]+:", r))
        ]
      ]
    ]))
    error_message = "Every resource ARN names its service: IAM rejects arn:<partition>:*:... as MalformedPolicyDocument."
  }

  assert {
    condition     = alltrue([for k, p in aws_iam_policy.workload_boundary : length(replace(p.policy, "/\\s/", "")) <= 6144])
    error_message = "A managed policy holds at most 6,144 characters (IAM quota)."
  }

  assert {
    condition = alltrue([
      for arn in ["arn:aws:s3:::acme-shared-tfstate-123456789012/*/prod/*", "arn:aws:s3:::acme-shared-tfstate-123456789012/plans/*"] :
      contains(flatten([for s in jsondecode(aws_iam_role_policy.apply_production_deny["dev"].policy).Statement : s.Resource if s.Sid == "ProductionDenyStateAndPlans"]), arn)
    ])
    error_message = "gha-apply-dev must not touch prod state or saved plans."
  }

  assert {
    condition = join(",", flatten([
      for s in jsondecode(aws_iam_role_policy.apply_production_deny["dev"].policy).Statement : s.Resource if s.Sid == "ProductionDenyPassRole"
    ])) == "arn:aws:iam::123456789012:role/workload/prod/*"
    error_message = "gha-apply-dev must not pass prod workload roles."
  }

  assert {
    condition = (
      length([for s in jsondecode(aws_iam_role_policy.apply_state["prod"].policy).Statement : s if s.Sid == "SavedPlansProductionOnly"]) == 0 &&
      length([for s in jsondecode(aws_iam_role_policy.apply_state["dev"].policy).Statement : s if s.Sid == "SavedPlansProductionOnly"]) == 1
    )
    error_message = "Only the prod apply role may read saved plans."
  }

  assert {
    condition = join(",", flatten([
      for s in jsondecode(aws_iam_role_policy.plan_state["pr"].policy).Statement : s.Resource if s.Sid == "ProductionStateNotReadable"
    ])) == "arn:aws:s3:::acme-shared-tfstate-123456789012/*/prod/*"
    error_message = "gha-plan-pr must not read prod state."
  }
}

run "production_environment_must_be_named" {
  command = plan

  variables {
    account_mode = "single"
    environments = ["dev", "prod"]
  }

  # The default production_environments, ["production"], is not in environments: refused, never silently open.
  expect_failures = [var.production_environments]
}

run "single_account_needs_a_production_environment" {
  command = plan

  variables {
    account_mode            = "single"
    production_environments = []
  }

  expect_failures = [var.production_environments]
}

run "production_is_always_production" {
  command = plan

  variables {
    production_environments = ["dev"]
  }

  expect_failures = [var.production_environments]
}

run "landing_zone_dev_account" {
  command = plan

  variables {
    account_mode            = "landing-zone"
    environments            = ["dev"]
    production_environments = []
  }

  assert {
    condition     = length(aws_iam_role_policy.apply_production_deny) == 0
    error_message = "A dev-only account needs no ProductionDeny."
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.apply_state["dev"].policy).Statement : s if s.Sid == "SavedPlansProductionOnly"]) == 1
    error_message = "A dev apply role never reads saved plans."
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.plan_state["pr"].policy).Statement : s if s.Sid == "ProductionStateNotReadable"]) == 0
    error_message = "With no production environment there is no production state deny, and no statement with an empty resource list."
  }
}

run "workload_roles_only_in_own_path" {
  command = plan

  assert {
    condition = alltrue([
      for e in ["dev", "production"] : length([
        for s in jsondecode(aws_iam_role_policy.apply_workload_iam[e].policy).Statement : s
        if s.Sid == "TrustOnlyOwnWorkloadRoles" && s.Effect == "Deny" &&
        toset(s.Action) == toset(["iam:CreateRole", "iam:UpdateAssumeRolePolicy"]) &&
        s.NotResource == "arn:aws:iam::123456789012:role/workload/${e}/*"
      ]) == 1
    ])
    error_message = "Each apply role must be denied creating or re-trusting any role outside /workload/<its environment>/."
  }
}

run "state_bucket_settings_and_key_denies" {
  command = plan

  # Every bucket setting that PowerUserAccess leaves open must fall under a deny pattern.
  assert {
    condition = alltrue([
      for e in ["dev", "production"] : alltrue([
        for a in [
          "s3:PutBucketRequestPayment", "s3:PutBucketObjectLockConfiguration", "s3:PutBucketNotification", "s3:PutBucketLogging",
          "s3:PutInventoryConfiguration", "s3:PutReplicationConfiguration", "s3:PutAnalyticsConfiguration", "s3:PutMetricsConfiguration",
          "s3:PutIntelligentTieringConfiguration", "s3:PutAccelerateConfiguration", "s3:PutBucketTagging", "s3:PutBucketWebsite",
          "s3:PutBucketCORS", "s3:PutBucketPolicy", "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration", "s3:PutLifecycleConfiguration",
          "s3:DeleteBucket", "s3:DeleteBucketPolicy", "s3:CreateBucketMetadataTableConfiguration",
          ] : anytrue([
            for s in jsondecode(aws_iam_role_policy.apply_foundation_protect[e].policy).Statement : anytrue([
              for p in flatten([s.Action]) : can(regex("^${replace(p, "*", ".*")}$", a))
            ]) if s.Sid == "ProtectStateBucket" && s.Effect == "Deny" && s.Resource == "arn:aws:s3:::acme-shared-tfstate-123456789012"
        ])
      ])
    ])
    error_message = "ProtectStateBucket must deny every bucket-level setting of the state bucket, Requester Pays and Object Lock included."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s
      if s.Sid == "DenyBucketSettingsToPipelineRoles" && s.Effect == "Deny" && s.Principal == "*" &&
      contains(flatten([s.Action]), "s3:PutBucket*") &&
      toset(s.Condition.ArnLike["aws:PrincipalArn"]) == toset(["arn:aws:iam::123456789012:role/gha-*", "arn:aws:iam::123456789012:role/workload/*"])
    ]) == 1
    error_message = "The bucket policy must also deny bucket settings to every GitHub role and workload role."
  }

  assert {
    condition = alltrue([
      for e in ["dev", "production"] : length(setsubtract(
        toset(["kms:CreateGrant", "kms:RetireGrant", "kms:RevokeGrant", "kms:PutKeyPolicy", "kms:ScheduleKeyDeletion"]),
        toset(flatten([for s in jsondecode(aws_iam_role_policy.apply_foundation_protect[e].policy).Statement : s.Action if s.Sid == "ProtectStateKey" && s.Effect == "Deny"]))
      )) == 0
    ])
    error_message = "Apply roles must not create or remove grants on the state key."
  }

  assert {
    condition = alltrue([
      for e in ["dev", "production"] : length([
        for s in jsondecode(aws_iam_role_policy.apply_foundation_protect[e].policy).Statement : s
        if s.Sid == "StateKeyOnlyThroughS3" && s.Effect == "Deny" &&
        toset(s.Action) == toset(["kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*"]) &&
        s.Resource == "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000" &&
        s.Condition.StringNotEquals["kms:ViaService"] == "s3.ap-southeast-2.amazonaws.com"
      ]) == 1
    ])
    error_message = "Apply roles may use the state key only through S3 in the bootstrap Region."
  }

  # Rotation is part of the key's protection: an apply role can neither change the state key's rotation period nor
  # rotate it on demand (ported from Terraform-AWS's bootstrap template, AC-1.7 of its change 0025).
  assert {
    condition = alltrue([
      for e in ["dev", "production"] : alltrue([
        for a in ["kms:EnableKeyRotation", "kms:RotateKeyOnDemand"] : length([
          for s in jsondecode(aws_iam_role_policy.apply_foundation_protect[e].policy).Statement : s
          if s.Sid == "ProtectStateKey" && s.Effect == "Deny" && !contains(keys(s), "Condition") &&
          contains(flatten([s.Action]), a)
        ]) == 1
      ])
    ])
    error_message = "Apply roles can neither change the state key's rotation period nor rotate it on demand."
  }

  # The S3 backend path stays open: the allows name the same service as the denies.
  assert {
    condition = alltrue(concat(
      [for e in ["dev", "production"] : length([
        for s in jsondecode(aws_iam_role_policy.apply_state[e].policy).Statement : s
        if s.Sid == "StateKeyThroughS3" && s.Effect == "Allow" && s.Condition.StringEquals["kms:ViaService"] == "s3.ap-southeast-2.amazonaws.com"
      ]) == 1],
      [for k in ["pr", "default"] : length([
        for s in jsondecode(aws_iam_role_policy.plan_state[k].policy).Statement : s
        if s.Sid == "StateKeyThroughS3" && s.Effect == "Allow" && s.Condition.StringEquals["kms:ViaService"] == "s3.ap-southeast-2.amazonaws.com"
      ]) == 1],
      [for k in ["pr", "default"] : length([
        for s in jsondecode(aws_iam_role_policy.plan_data_plane_deny[k].policy).Statement : s
        if s.Sid == "DataPlaneDenyDecryptOutsideState" && s.Effect == "Deny" && s.Resource == "*" &&
        contains(s.Action, "kms:Decrypt") && contains(s.Action, "kms:ReEncrypt*") && contains(s.Action, "kms:GenerateDataKey*") &&
        s.Condition.StringNotEquals["kms:ViaService"] == "s3.ap-southeast-2.amazonaws.com"
      ]) == 1],
    ))
    error_message = "Apply and plan roles must reach the state key through S3 only, and the S3 allow must stay."
  }
}

run "state_bucket_controls" {
  command = plan

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State bucket versioning must be on."
  }

  assert {
    condition = alltrue([
      for r in aws_s3_bucket_server_side_encryption_configuration.state.rule :
      r.bucket_key_enabled && r.apply_server_side_encryption_by_default[0].sse_algorithm == "aws:kms"
    ])
    error_message = "State must use SSE-KMS with a bucket key."
  }

  assert {
    condition     = aws_s3_bucket_ownership_controls.state.rule[0].object_ownership == "BucketOwnerEnforced"
    error_message = "Object ownership must be BucketOwnerEnforced."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "All four public access blocks must be on."
  }

  assert {
    condition     = contains([for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s.Sid], "DenyInsecureTransport")
    error_message = "The bucket policy must refuse requests without TLS."
  }

  assert {
    condition = length([
      for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s
      if s.Sid == "DenyKmsWithoutStateKey" && s.Effect == "Deny" &&
      s.Condition.Null["s3:x-amz-server-side-encryption"] == "false" && s.Condition.Null["s3:x-amz-server-side-encryption-aws-kms-key-id"] == "true"
    ]) == 1
    error_message = "The bucket policy must refuse aws:kms uploads that name no key, which S3 would encrypt with aws/s3."
  }

  assert {
    condition = alltrue([
      for e in ["dev", "production"] : alltrue([
        for pair in [
          [aws_iam_role_policy.apply_foundation_protect[e].policy, "ProtectBootstrapState"],
          [aws_iam_role_policy.apply_state[e].policy, "SavedPlansReadOnly"],
          ] : length(setsubtract(
            toset(["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutObjectVersionTagging"]),
            toset(flatten([for s in jsondecode(pair[0]).Statement : s.Action if s.Sid == pair[1] && s.Effect == "Deny"]))
        )) == 0
      ])
    ])
    error_message = "Apply roles must not overwrite, delete or delete versions of the bootstrap state or saved plans."
  }

  assert {
    condition = alltrue([
      for r in aws_s3_bucket_lifecycle_configuration.state.rule : length(r.abort_incomplete_multipart_upload) == 1
    ])
    error_message = "Every lifecycle rule must abort incomplete uploads."
  }

  assert {
    condition     = aws_kms_key.state[0].enable_key_rotation
    error_message = "The state key must rotate."
  }
}

run "plans_expire_after_seven_days" {
  command = plan

  assert {
    condition = length([
      for r in aws_s3_bucket_lifecycle_configuration.state.rule : r
      if r.id == "plans-expire" && r.filter[0].prefix == "plans/" && r.expiration[0].days == 7
    ]) == 1
    error_message = "Saved plans under plans/ must expire after 7 days."
  }
}

run "budget_notifies_at_80_and_100" {
  command = plan

  assert {
    condition = (
      length([for n in aws_budgets_budget.account.notification : n if n.notification_type == "ACTUAL"]) == 2 &&
      toset([for n in aws_budgets_budget.account.notification : n.threshold if n.notification_type == "ACTUAL"]) == toset([80, 100])
    )
    error_message = "The account budget needs exactly two actual-cost notifications, at 80% and 100%."
  }
}

run "guardrail_denies_writes_secrets_and_mcp_writes" {
  command = plan

  assert {
    condition = alltrue([
      for sid in ["DenyWrites", "DenyMcpNonRead", "DenySecretReads", "DenyDataPlaneReads", "DenyTokenCalls"] :
      contains([for s in jsondecode(output.automation_guardrail_policy_json).Statement : s.Sid if s.Effect == "Deny"], sid)
    ])
    error_message = "The automation guardrail is missing a deny statement."
  }

  assert {
    condition = alltrue([
      for a in [
        "cloudtrail:Stop*", "cloudtrail:Delete*", "identitystore:Create*", "config:Delete*", "wafv2:Disassociate*",
        "cloudwatch:DeleteAlarms", "scheduler:Create*", "execute-api:Invoke", "acm:Delete*", "iam:PassRole",
      ] :
      contains(flatten([for s in jsondecode(output.automation_guardrail_policy_json).Statement : s.Action if s.Sid == "DenyWrites"]), a)
    ])
    error_message = "The guardrail must deny audit, identity, edge, alarm, schedule and API-call writes as well as infrastructure writes."
  }

  assert {
    condition = alltrue([
      for a in ["apigateway:GET", "states:GetExecutionHistory", "states:DescribeExecution", "dynamodb:Scan"] :
      contains(flatten([for s in jsondecode(output.automation_guardrail_policy_json).Statement : try(s.Action, []) if s.Effect == "Deny" && s.Sid != "DenyWrites"]), a)
    ])
    error_message = "The guardrail must deny API key values, execution data and table items."
  }

  assert {
    condition     = length(output.automation_guardrail_policy_json) < 10240
    error_message = "The guardrail must fit an IAM Identity Center inline policy."
  }
}

run "api_gateway_logging_role_on_by_default" {
  command = plan

  assert {
    condition     = length(aws_api_gateway_account.this) == 1 && length(aws_iam_role.api_gateway_logs) == 1
    error_message = "REST API stages need the account's API Gateway logging role, so the bootstrap sets it by default."
  }
}

run "region_has_no_default" {
  command = plan

  variables {
    region = ""
  }

  expect_failures = [var.region]
}

run "wildcard_repo_rejected" {
  command = plan

  variables {
    github_repositories = ["acme/*"]
  }

  expect_failures = [var.github_repositories]
}

run "workload_boundary_protects_security_baseline" {
  command = plan

  assert {
    condition = length(aws_iam_policy.workload_boundary) == 2 && alltrue([
      for p in values(aws_iam_policy.workload_boundary) : length([
        for s in jsondecode(p.policy).Statement : s
        if s.Sid == "ProtectSecurityBaseline" && s.Effect == "Deny" && !contains(keys(s), "Action") && !contains(keys(s), "Condition") &&
        toset(try(s.NotAction, [])) == toset(["sns:Get*", "sns:List*", "events:Describe*", "events:List*"]) &&
        s.Resource == [
          "arn:aws:sns:*:123456789012:security-baseline-*",
          "arn:aws:events:*:123456789012:rule/security-baseline-*",
        ]
      ]) == 1
    ])
    error_message = "Every workload boundary must deny changes to the security baseline's topic, its subscriptions and tags, and its rules."
  }

  # Each write to the topic or the rules matches no kept read, so it is denied.
  assert {
    condition = alltrue(flatten([
      for p in values(aws_iam_policy.workload_boundary) : [
        for a in [
          "sns:Unsubscribe", "sns:SetSubscriptionAttributes", "sns:DeleteTopic", "sns:SetTopicAttributes", "sns:AddPermission",
          "sns:RemovePermission", "sns:Subscribe", "sns:PutDataProtectionPolicy", "sns:UntagResource", "sns:TagResource", "sns:Publish",
          "events:DeleteRule", "events:DisableRule", "events:PutRule", "events:PutTargets", "events:RemoveTargets", "events:UntagResource",
          ] : !anytrue([
            for r in flatten([for s in jsondecode(p.policy).Statement : s.NotAction if s.Sid == "ProtectSecurityBaseline"]) :
            can(regex("^${replace(r, "*", ".*")}$", a))
        ])
      ]
    ]))
    error_message = "No write on the baseline's topic or rules may fall under the reads a workload role keeps."
  }

  # The same default bus ProtectSecurityBaseline's rules run on; its own statement, so events:PutEvents stays open.
  assert {
    condition = alltrue([
      for p in values(aws_iam_policy.workload_boundary) : length([
        for s in jsondecode(p.policy).Statement : s
        if s.Sid == "ProtectDefaultEventBus" && s.Effect == "Deny" && !contains(keys(s), "Condition") &&
        toset(flatten([try(s.Action, [])])) == toset(["events:UpdateEventBus"]) &&
        length(setsubtract(
          toset([
            "arn:aws:events:*:123456789012:event-bus/default",
            "arn:aws:events:*:123456789012:event-busv2/default/*",
          ]),
          toset(flatten([try(s.Resource, [])]))
        )) == 0
      ]) == 1
    ])
    error_message = "Every workload boundary must deny changing or re-keying the default event bus, in every Region, with no condition."
  }

  # WorkloadServices itself never names these; this guards a later edit from silently reopening a route left closed with no dedicated deny.
  assert {
    condition = alltrue([
      for p in values(aws_iam_policy.workload_boundary) : alltrue([
        for a in [
          "kms:CreateKey", "kms:PutKeyPolicy", "kms:EnableKeyRotation", "kms:RotateKeyOnDemand", "kms:ScheduleKeyDeletion", "kms:DisableKey",
          "ec2:CreateDefaultVpc", "guardduty:AcceptAdministratorInvitation", "guardduty:AcceptInvitation",
          "securityhub:AcceptAdministratorInvitation", "securityhub:AcceptInvitation",
          ] : !anytrue([
            for s in jsondecode(p.policy).Statement : (
              contains(keys(s), "Action") ?
              anytrue([for act in flatten([s.Action]) : can(regex("^${replace(replace(lower(act), "*", ".*"), "?", ".")}$", lower(a)))]) :
              !anytrue([for act in flatten([try(s.NotAction, [])]) : can(regex("^${replace(replace(lower(act), "*", ".*"), "?", ".")}$", lower(a)))])
            )
            if s.Effect == "Allow"
        ])
      ])
    ])
    error_message = "No workload boundary may allow key management, ec2:CreateDefaultVpc, or accepting a GuardDuty or Security Hub administrator invitation, by any case or wildcard."
  }

  assert {
    condition = alltrue([
      for p in values(aws_iam_policy.workload_boundary) : length([
        for s in jsondecode(p.policy).Statement : s
        if s.Sid == "ProtectAccountPublicAccessBlock" && s.Effect == "Deny" && !contains(keys(s), "Condition") &&
        s.Action == "s3:PutAccountPublicAccessBlock" && s.Resource == "*"
      ]) == 1
    ])
    error_message = "Every workload boundary must deny changing the account-wide S3 public access block, which s3:* would otherwise allow."
  }

  # The trail log group: every logs action but reading and querying the events, with no condition.
  assert {
    condition = alltrue([
      for p in values(aws_iam_policy.workload_boundary) : length([
        for s in jsondecode(p.policy).Statement : s
        if s.Sid == "ProtectSecurityBaselineLogs" && s.Effect == "Deny" && !contains(keys(s), "Action") && !contains(keys(s), "Condition") &&
        toset(try(s.NotAction, [])) == toset([
          "logs:Get*", "logs:Describe*", "logs:List*", "logs:FilterLogEvents", "logs:StartQuery", "logs:StopQuery",
          "logs:GetQueryResults", "logs:StartLiveTail", "logs:StopLiveTail",
        ]) &&
        s.Resource == [
          "arn:aws:logs:*:123456789012:log-group:security-baseline-*",
          "arn:aws:logs:*:123456789012:log-group:security-baseline-*:*",
        ]
      ]) == 1
    ])
    error_message = "Every workload boundary must deny every logs action on the baseline's log group except reading and querying its events."
  }

  # Each write that could hide, reshape, copy out or add to the trail's events matches no kept read, so it is denied.
  # logs:PutIndexPolicy is not in this list: IAM gives it no resource type, so no log-group deny ever
  # reaches it, and asserting it here proved only that its name matches none of the kept reads.
  assert {
    condition = alltrue(flatten([
      for p in values(aws_iam_policy.workload_boundary) : [
        for a in [
          "logs:PutLogEvents", "logs:CreateLogStream", "logs:PutSubscriptionFilter", "logs:CreateExportTask", "logs:UntagResource",
          "logs:UntagLogGroup", "logs:TagResource", "logs:PutLogGroupDeletionProtection", "logs:PutBearerTokenAuthentication",
          "logs:PutRetentionPolicy", "logs:PutMetricFilter", "logs:DeleteMetricFilter", "logs:DeleteLogGroup",
          "logs:AssociateKmsKey", "logs:DisassociateKmsKey", "logs:PutDataProtectionPolicy", "logs:PutTransformer",
          "logs:ProcessWithPipeline", "logs:Unmask",
          ] : !anytrue([
            for r in flatten([for s in jsondecode(p.policy).Statement : s.NotAction if s.Sid == "ProtectSecurityBaselineLogs"]) :
            can(regex("^${replace(r, "*", ".*")}$", a))
        ])
      ]
    ]))
    error_message = "No write on the baseline's log group may fall under the reads a workload role keeps."
  }

  # Account-level logs policies apply to the trail log group without naming it.
  assert {
    condition = alltrue([
      for p in values(aws_iam_policy.workload_boundary) : length([
        for s in jsondecode(p.policy).Statement : s
        if s.Sid == "ProtectLogsAccountPolicies" && s.Effect == "Deny" && !contains(keys(s), "Condition") && s.Resource == "*" &&
        toset(flatten([try(s.Action, [])])) == toset(["logs:PutAccountPolicy", "logs:DeleteAccountPolicy"])
      ]) == 1
    ])
    error_message = "Every workload boundary must deny setting or removing an account-level logs policy."
  }

  assert {
    condition = alltrue([
      for p in values(aws_iam_policy.workload_boundary) : length([
        for s in jsondecode(p.policy).Statement : s
        if s.Sid == "ProtectSecurityBaselineMetrics" && s.Effect == "Deny" && s.Action == "cloudwatch:PutMetricData" && s.Resource == "*" &&
        jsonencode(s.Condition) == jsonencode({ StringEquals = { "cloudwatch:namespace" = "SecurityBaseline" } })
      ]) == 1
    ])
    error_message = "Every workload boundary must deny writing metrics into the SecurityBaseline namespace, which the baseline's alarms read."
  }

  assert {
    condition = alltrue([
      for p in values(aws_iam_policy.workload_boundary) : contains(flatten([
        for s in jsondecode(p.policy).Statement : s.Action if s.Sid == "WorkloadServices"
      ]), "cloudwatch:PutMetricData")
    ])
    error_message = "Workload roles still write their own metrics: only the SecurityBaseline namespace is denied."
  }
}

run "security_baseline_protection_can_be_turned_off" {
  command = plan
  variables {
    protect_security_baseline = false
  }

  assert {
    condition = alltrue([
      for p in values(aws_iam_policy.workload_boundary) : length([
        for s in jsondecode(p.policy).Statement : s
        if startswith(s.Sid, "ProtectSecurityBaseline") || contains(["ProtectDefaultEventBus", "ProtectLogsAccountPolicies", "ProtectAccountPublicAccessBlock"], s.Sid)
      ]) == 0
    ])
    error_message = "With protect_security_baseline = false no workload boundary carries a security baseline deny."
  }
}

run "security_baseline_prefix_renames_the_protected_resources" {
  command = plan
  variables {
    security_baseline_prefix = "sb"
  }

  assert {
    condition = alltrue([
      for p in values(aws_iam_policy.workload_boundary) : length([
        for s in jsondecode(p.policy).Statement : s
        if s.Sid == "ProtectSecurityBaseline" && s.Resource == [
          "arn:aws:sns:*:123456789012:sb-*",
          "arn:aws:events:*:123456789012:rule/sb-*",
        ]
      ]) == 1
    ])
    error_message = "security_baseline_prefix must replace security-baseline in every protected name."
  }
}

run "no_break_glass_user_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_user.break_glass) == 0 && length(aws_iam_user_policy_attachment.break_glass_admin) == 0 && length(aws_iam_user_policy.break_glass_require_mfa) == 0 && output.break_glass_user_arn == null
    error_message = "a workload account gets no break-glass user unless asked"
  }
}

run "break_glass_user_has_no_key_and_needs_mfa" {
  command = plan
  variables {
    ci_roles         = false
    break_glass_user = true
  }

  assert {
    condition     = aws_iam_user.break_glass[0].name == "break-glass" && aws_iam_user.break_glass[0].path == "/break-glass/" && aws_iam_user_policy_attachment.break_glass_admin[0].policy_arn == "arn:aws:iam::aws:policy/AdministratorAccess"
    error_message = "one break-glass user with administrator rights, on the default path"
  }
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_user_policy.break_glass_require_mfa[0].policy).Statement :
      s.Effect == "Deny" && s.Condition.BoolIfExists["aws:MultiFactorAuthPresent"] == "false" && !contains(s.NotAction, "iam:CreateAccessKey")
    ])
    error_message = "everything but MFA and password setup is denied without MFA, and access key creation is never exempt"
  }
}

run "break_glass_path_keeps_a_console_made_user_unchanged" {
  command = plan
  variables {
    ci_roles         = false
    break_glass_user = true
    break_glass_path = "/"
  }

  assert {
    condition     = aws_iam_user.break_glass[0].path == "/"
    error_message = "a user made in the console has the path /; the module must keep it so an import changes nothing"
  }
}

run "break_glass_path_must_start_and_end_with_slash" {
  command = plan
  variables {
    break_glass_path = "break-glass"
  }

  expect_failures = [var.break_glass_path]
}

# The management-account root of a consumer pinned before 3.0.0 calls the module with these inputs and keeps
# its live state bucket, key, budget and break-glass user by address: a plan of that root shows no replacement.
run "management_account_root_keeps_its_addresses" {
  command = plan
  variables {
    ci_roles                   = false
    enable_api_gateway_account = false
    account_mode               = "landing-zone"
    environments               = ["dev"]
    production_environments    = []
    break_glass_user           = true
    break_glass_path           = "/"
    alternate_contacts = {
      security = { name = "Fixture Owner", title = "Owner", email = "security@example.com", phone = "+64000000000" }
    }
  }

  assert {
    condition = (
      aws_s3_bucket.state.bucket == "acme-shared-tfstate-123456789012" &&
      length(aws_kms_key.state) == 1 && length(aws_kms_alias.state) == 1 &&
      aws_budgets_budget.account.limit_amount == "250.00" &&
      length(aws_iam_user.break_glass) == 1 && length(aws_iam_user_policy_attachment.break_glass_admin) == 1 &&
      length(aws_iam_user_policy.break_glass_require_mfa) == 1 &&
      contains(keys(aws_account_alternate_contact.this), "security")
    )
    error_message = "the bucket, key, alias, budget, break-glass user, its two policies and the alternate contacts keep the addresses the earlier pin gave them"
  }

  assert {
    condition     = length(aws_iam_role.plan) == 0 && length(aws_iam_role.apply) == 0 && length(aws_iam_openid_connect_provider.github) == 0 && length(aws_iam_policy.workload_boundary) == 0
    error_message = "a management account bootstrap has no pipeline role, provider or boundary"
  }
}
