# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Tier 1: plan-only tests with a mocked AWS provider for the module's reuse inputs: names per
# tenant, an existing OIDC provider, repository and workflow claims, apply policies, the account
# and Region checks, the forecast notification, session length, tags, lifecycle days and ci_roles.
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

# No state_bucket_name and no change_id: the defaults are under test here.
variables {
  account_id          = "123456789012"
  region              = "ap-southeast-2"
  github_repositories = ["acme/platform"]
  default_branch      = "develop"
  budget_limit_usd    = 250
  notification_email  = "finance@example.com"
}

run "default_names_unchanged" {
  command = plan

  assert {
    condition = (
      join(",", output.plan_role_names) == "gha-plan-pr,gha-plan-default" &&
      join(",", sort([for r in values(aws_iam_role.apply) : r.name])) == "gha-apply-dev,gha-apply-production"
    )
    error_message = "With the default name_prefix the delivery roles keep the names the delivery workflows assume."
  }

  assert {
    condition = (
      aws_kms_alias.state[0].name == "alias/platform-shared-tfstate" &&
      aws_budgets_budget.account.name == "platform-shared-monthly-cost" &&
      aws_iam_role.api_gateway_logs[0].name == "platform-shared-apigateway-logs" &&
      aws_iam_policy.workload_boundary["dev"].name == "platform-dev-workload-boundary"
    )
    error_message = "With the default name_prefix the alias, budget, logging role and boundaries keep their names."
  }

  assert {
    condition = contains(flatten([
      for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s.Condition.ArnLike["aws:PrincipalArn"] if s.Sid == "DenyBucketSettingsToPipelineRoles"
    ]), "arn:aws:iam::123456789012:role/gha-*")
    error_message = "The bucket policy must name the default delivery roles, role/gha-*."
  }
}

run "default_bucket_name" {
  command = plan

  assert {
    condition     = aws_s3_bucket.state.bucket == "123456789012-tfstate-ap-southeast-2"
    error_message = "With no state_bucket_name the bucket is <account_id>-tfstate-<region>, the tenant convention."
  }

  assert {
    condition     = output.backend_settings.bucket == "123456789012-tfstate-ap-southeast-2" && output.state_bucket_name == "123456789012-tfstate-ap-southeast-2"
    error_message = "backend_settings and state_bucket_name must carry the computed bucket name."
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement :
      alltrue([for r in flatten([s.Resource]) : startswith(r, "arn:aws:s3:::123456789012-tfstate-ap-southeast-2")])
    ])
    error_message = "Every bucket policy statement must name the computed bucket."
  }
}

run "name_prefix_renames_every_delivery_role" {
  command = plan

  variables {
    name_prefix = "tenantb"
  }

  assert {
    condition = (
      join(",", output.plan_role_names) == "tenantb-plan-pr,tenantb-plan-default" &&
      join(",", sort([for r in values(aws_iam_role.apply) : r.name])) == "tenantb-apply-dev,tenantb-apply-production"
    )
    error_message = "name_prefix must rename both plan roles and every apply role."
  }

  assert {
    condition = (
      aws_kms_alias.state[0].name == "alias/tenantb-platform-shared-tfstate" &&
      aws_budgets_budget.account.name == "tenantb-platform-shared-monthly-cost" &&
      aws_iam_role.api_gateway_logs[0].name == "tenantb-platform-shared-apigateway-logs" &&
      join(",", sort([for p in values(aws_iam_policy.workload_boundary) : p.name])) == "tenantb-platform-dev-workload-boundary,tenantb-platform-production-workload-boundary" &&
      aws_s3_bucket.state.bucket == "123456789012-tenantb-tfstate-ap-southeast-2"
    )
    error_message = "Any other name_prefix must go in front of the alias, budget, logging role, boundary and default bucket names."
  }

  assert {
    condition = alltrue([
      for e in ["dev", "production"] : (
        contains(flatten([for s in jsondecode(aws_iam_role_policy.apply_foundation_protect[e].policy).Statement : s.Resource if s.Sid == "ProtectDeliveryIdentity"]), "arn:aws:iam::123456789012:role/tenantb-*") &&
        !contains(flatten([for s in jsondecode(aws_iam_role_policy.apply_foundation_protect[e].policy).Statement : s.Resource if s.Sid == "ProtectDeliveryIdentity"]), "arn:aws:iam::123456789012:role/gha-*") &&
        contains(flatten([for s in jsondecode(aws_iam_role_policy.apply_foundation_protect[e].policy).Statement : s.Resource if s.Sid == "ProtectBudget"]), "arn:aws:budgets::123456789012:budget/tenantb-platform-shared-monthly-cost")
      )
    ])
    error_message = "FoundationProtect must protect this tenant's roles, role/tenantb-*, and its own budget."
  }

  assert {
    condition = contains(flatten([
      for s in jsondecode(aws_s3_bucket_policy.state.policy).Statement : s.Condition.ArnLike["aws:PrincipalArn"] if s.Sid == "DenyBucketSettingsToPipelineRoles"
    ]), "arn:aws:iam::123456789012:role/tenantb-*")
    error_message = "The bucket policy must deny bucket settings to this tenant's roles, role/tenantb-*."
  }
}

run "name_prefix_with_hyphen_rejected" {
  command = plan

  variables {
    name_prefix = "gha-b"
  }

  # role/gha-* would match another tenant's gha-b-* roles.
  expect_failures = [var.name_prefix]
}

run "existing_oidc_provider_is_trusted" {
  command = plan

  variables {
    create_oidc_provider = false
    oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0
    error_message = "With create_oidc_provider = false the module must not create a provider."
  }

  assert {
    condition = alltrue([
      for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) :
      jsondecode(r.assume_role_policy).Statement[0].Principal.Federated == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    ])
    error_message = "Every GitHub role must trust the given provider."
  }

  assert {
    condition     = output.oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "oidc_provider_arn must report the provider in use."
  }
}

run "existing_oidc_provider_needs_its_arn" {
  command = plan

  variables {
    create_oidc_provider = false
  }

  expect_failures = [var.oidc_provider_arn]
}

run "no_id_claims_by_default" {
  command = plan

  assert {
    condition = alltrue([
      for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) :
      toset(keys(jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals)) == toset(["token.actions.githubusercontent.com:aud", "token.actions.githubusercontent.com:sub"])
    ])
    error_message = "Without repository or owner IDs every trust checks only aud and sub."
  }
}

run "repository_and_owner_ids_when_set" {
  command = plan

  variables {
    github_repository_ids = ["123456789"]
    github_owner_id       = "987654"
  }

  assert {
    condition = alltrue([
      for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) : (
        jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:repository_id"] == ["123456789"] &&
        jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:repository_owner_id"] == "987654"
      )
    ])
    error_message = "Every trust must require the repository ID and the owner ID, with StringEquals."
  }
}

run "several_repositories" {
  command = plan

  variables {
    github_repositories = ["acme/platform", "acme/site"]
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.plan["pr"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:acme/platform:pull_request", "repo:acme/site:pull_request"] &&
      jsondecode(aws_iam_role.apply["production"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:acme/platform:environment:production", "repo:acme/site:environment:production"]
    )
    error_message = "Each role must trust the exact subject of every listed repository."
  }
}

run "workflow_ref_only_on_configured_apply_role" {
  command = plan

  variables {
    apply_workflow_refs = { production = ["acme/platform/.github/workflows/release.yml@refs/heads/develop"] }
  }

  assert {
    condition     = jsondecode(aws_iam_role.apply["production"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:job_workflow_ref"] == ["acme/platform/.github/workflows/release.yml@refs/heads/develop"]
    error_message = "The production apply role must require the listed workflow, with StringEquals."
  }

  assert {
    condition = alltrue([
      for r in [aws_iam_role.apply["dev"], aws_iam_role.plan["pr"], aws_iam_role.plan["default"]] :
      !strcontains(r.assume_role_policy, "job_workflow_ref")
    ])
    error_message = "Roles of environments that apply_workflow_refs does not list must not check job_workflow_ref."
  }

  assert {
    condition     = keys(jsondecode(aws_iam_role.apply["production"].assume_role_policy).Statement[0].Condition) == ["StringEquals"]
    error_message = "Exact workflow refs need no StringLike."
  }
}

run "workflow_ref_wildcard_uses_string_like" {
  command = plan

  variables {
    apply_workflow_refs = { production = ["acme/platform/.github/workflows/release.yml@refs/tags/*"] }
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.apply["production"].assume_role_policy).Statement[0].Condition.StringLike["token.actions.githubusercontent.com:job_workflow_ref"] == ["acme/platform/.github/workflows/release.yml@refs/tags/*"] &&
      !contains(keys(jsondecode(aws_iam_role.apply["production"].assume_role_policy).Statement[0].Condition.StringEquals), "token.actions.githubusercontent.com:job_workflow_ref") &&
      jsondecode(aws_iam_role.apply["production"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:acme/platform:environment:production"]
    )
    error_message = "A wildcard workflow ref goes under StringLike; sub stays StringEquals."
  }
}

run "workflow_refs_only_for_listed_environments" {
  command = plan

  variables {
    apply_workflow_refs = { staging = ["acme/platform/.github/workflows/release.yml@refs/heads/develop"] }
  }

  expect_failures = [var.apply_workflow_refs]
}

run "apply_policy_default_is_power_user" {
  command = plan

  assert {
    condition = toset(keys(aws_iam_role_policy_attachment.apply_policies)) == toset([
      "dev|arn:aws:iam::aws:policy/PowerUserAccess", "production|arn:aws:iam::aws:policy/PowerUserAccess",
    ])
    error_message = "Without apply_policy_arns every apply role carries PowerUserAccess, built with the partition."
  }
}

run "apply_policy_arns_override" {
  command = plan

  variables {
    apply_policy_arns = ["arn:aws:iam::123456789012:policy/tenant-apply"]
  }

  assert {
    condition = (
      length(aws_iam_role_policy_attachment.apply_policies) == 2 &&
      toset([for a in values(aws_iam_role_policy_attachment.apply_policies) : a.policy_arn]) == toset(["arn:aws:iam::123456789012:policy/tenant-apply"]) &&
      toset([for a in values(aws_iam_role_policy_attachment.apply_policies) : a.role]) == toset(["gha-apply-dev", "gha-apply-production"])
    )
    error_message = "apply_policy_arns must replace PowerUserAccess on every apply role."
  }

  assert {
    condition     = length(aws_iam_role_policy.apply_foundation_protect) == 2 && length(aws_iam_role_policy.apply_production_deny) == 1
    error_message = "The inline denies stay whatever managed policies the apply roles carry."
  }
}

run "wrong_account_stops_the_plan" {
  command = plan

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "210987654321"
    }
  }

  expect_failures = [aws_kms_key.state]
}

run "wrong_region_stops_the_plan" {
  command = plan

  override_data {
    target = data.aws_region.current
    values = {
      region = "us-east-1"
    }
  }

  expect_failures = [aws_kms_key.state]
}

run "budget_has_forecast_notification" {
  command = plan

  assert {
    condition = length([
      for n in aws_budgets_budget.account.notification : n
      if n.notification_type == "FORECASTED" && n.threshold == 100 && n.comparison_operator == "GREATER_THAN" && n.subscriber_email_addresses == toset(["finance@example.com"])
    ]) == 1
    error_message = "The budget must email the owner when the forecast passes 100%."
  }
}

run "max_session_duration_applies_to_every_role" {
  command = plan

  variables {
    max_session_duration = 7200
  }

  assert {
    condition = alltrue([
      for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply), aws_iam_role.api_gateway_logs) : r.max_session_duration == 7200
    ])
    error_message = "max_session_duration must apply to every role."
  }
}

run "max_session_duration_out_of_range" {
  command = plan

  variables {
    max_session_duration = 60
  }

  expect_failures = [var.max_session_duration]
}

run "tags_follow_inputs" {
  command = plan

  variables {
    tags = { environment = "sandbox", managed-by = "manual", cost-centre = "cc-1" }
  }

  assert {
    condition     = !contains(keys(aws_iam_role.plan["pr"].tags), "change") && aws_iam_role.plan["pr"].tags["service"] == "platform"
    error_message = "With no change_id there is no change tag; the service tag stays."
  }

  assert {
    condition     = aws_iam_role.plan["pr"].tags["environment"] == "sandbox" && aws_iam_role.plan["pr"].tags["managed-by"] == "manual" && aws_s3_bucket.state.tags["cost-centre"] == "cc-1"
    error_message = "A key in tags wins over the module's own environment and managed-by keys."
  }

  assert {
    condition     = length([for k in keys(aws_iam_role.plan["pr"].tags) : k if contains(["environment", "managed-by"], k)]) == 2
    error_message = "A role carries each of environment and managed-by once."
  }
}

run "own_tags_are_kebab" {
  command = plan

  assert {
    condition     = aws_iam_role.plan["pr"].tags["managed-by"] == "terraform" && !contains(keys(aws_iam_role.plan["pr"].tags), "managed_by")
    error_message = "The module's own managed-by tag is kebab-case and its value is terraform."
  }
}

run "a_similar_key_does_not_replace_managed_by" {
  command = plan

  variables {
    tags = { managedby = "manual" }
  }

  assert {
    condition     = aws_iam_role.plan["pr"].tags["managed-by"] == "terraform" && aws_iam_role.plan["pr"].tags["managedby"] == "manual"
    error_message = "Only the exact key managed-by replaces the module's own tag; managedby sits beside it."
  }
}

run "tag_keys_must_be_kebab" {
  command = plan

  variables {
    tags = { managed_by = "manual" }
  }

  expect_failures = [var.tags]
}

run "change_tag_when_set" {
  command = plan

  variables {
    change_id = "0042"
  }

  assert {
    condition     = aws_kms_key.state[0].tags["change"] == "0042" && aws_iam_role.apply["dev"].tags["change"] == "0042" && aws_iam_role.apply["dev"].tags["environment"] == "shared"
    error_message = "change_id must become the change tag."
  }
}

run "lifecycle_days_are_inputs" {
  command = plan

  variables {
    noncurrent_version_expiration_days = 60
    plans_expiration_days              = 3
  }

  assert {
    condition = (
      length([for r in aws_s3_bucket_lifecycle_configuration.state.rule : r if r.id == "plans-expire" && r.expiration[0].days == 3]) == 1 &&
      length([for r in aws_s3_bucket_lifecycle_configuration.state.rule : r if r.id == "state-history" && r.noncurrent_version_expiration[0].noncurrent_days == 60]) == 1
    )
    error_message = "The plan and state-history lifecycle days must follow the inputs."
  }
}

run "immutable_subject_prefix" {
  command = plan

  variables {
    github_subject_prefixes = ["repo:acme@987654/platform@123456789"]
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.plan["pr"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:acme@987654/platform@123456789:pull_request"] &&
      jsondecode(aws_iam_role.apply["production"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:acme@987654/platform@123456789:environment:production"]
    )
    error_message = "With a subject prefix, every role must trust the exact immutable subject GitHub issues."
  }
}

run "subject_prefix_wildcard_rejected" {
  command = plan

  variables {
    github_subject_prefixes = ["repo:acme@987654/*"]
  }

  expect_failures = [var.github_subject_prefixes]
}

run "half_immutable_subject_prefix_rejected" {
  command = plan

  variables {
    github_subject_prefixes = ["repo:acme@987654/platform"]
  }

  expect_failures = [var.github_subject_prefixes]
}

run "subject_prefix_of_another_repository_rejected" {
  command = plan

  variables {
    github_subject_prefixes = ["repo:acme@987654/other@123456789"]
  }

  expect_failures = [var.github_subject_prefixes]
}

run "subject_prefix_count_must_match" {
  command = plan

  variables {
    github_subject_prefixes = ["repo:acme/platform", "repo:acme/site"]
  }

  expect_failures = [var.github_subject_prefixes]
}

# Default single-account inputs, so dev would get a ProductionDeny if any apply role were left.
run "ci_roles_off_creates_state_key_and_budget_only" {
  command = plan

  variables {
    ci_roles = false
  }

  assert {
    condition = (
      length(aws_iam_openid_connect_provider.github) == 0 &&
      length(aws_iam_role.plan) == 0 &&
      length(aws_iam_role.apply) == 0 &&
      length(aws_iam_policy.workload_boundary) == 0
    )
    error_message = "With ci_roles = false there is no OIDC provider, no plan or apply role and no workload boundary."
  }

  assert {
    condition = (
      length(aws_iam_role_policy_attachment.plan_read_only) == 0 &&
      length(aws_iam_role_policy_attachment.apply_policies) == 0 &&
      length(aws_iam_role_policy.plan_data_plane_deny) == 0 &&
      length(aws_iam_role_policy.plan_state) == 0 &&
      length(aws_iam_role_policy.apply_workload_iam) == 0 &&
      length(aws_iam_role_policy.apply_state) == 0 &&
      length(aws_iam_role_policy.apply_foundation_protect) == 0 &&
      length(aws_iam_role_policy.apply_production_deny) == 0
    )
    error_message = "With ci_roles = false no policy is attached to, or put on, a role that does not exist."
  }

  assert {
    condition = (
      aws_s3_bucket.state.bucket == "123456789012-tfstate-ap-southeast-2" &&
      aws_kms_key.state[0].enable_key_rotation &&
      aws_kms_alias.state[0].name == "alias/platform-shared-tfstate" &&
      aws_budgets_budget.account.name == "platform-shared-monthly-cost" &&
      length(aws_api_gateway_account.this) == 1
    )
    error_message = "With ci_roles = false the state bucket, key, budget and API Gateway logging setting remain."
  }
}

# The management account of a landing zone, as the README describes it.
run "ci_roles_off_outputs_are_null_or_empty" {
  command = plan

  variables {
    ci_roles                = false
    account_mode            = "landing-zone"
    environments            = ["management"]
    production_environments = []
  }

  assert {
    condition = (
      output.oidc_provider_arn == null &&
      length(output.plan_role_names) == 0 &&
      length(output.plan_role_arns) == 0 &&
      length(output.apply_role_arns) == 0 &&
      length(output.workload_boundary_policy_arns) == 0 &&
      length(output.workload_role_paths) == 0
    )
    error_message = "With ci_roles = false the OIDC output is null and every role, boundary and path output is empty."
  }

  assert {
    condition     = output.backend_settings.bucket == "123456789012-tfstate-ap-southeast-2" && output.budget_name == "platform-shared-monthly-cost"
    error_message = "With ci_roles = false the backend settings and the budget are still reported."
  }
}

run "ci_roles_off_needs_no_oidc_provider_arn" {
  command = plan

  variables {
    ci_roles             = false
    create_oidc_provider = false
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && output.oidc_provider_arn == null
    error_message = "With ci_roles = false, create_oidc_provider = false needs no oidc_provider_arn, and none is reported."
  }
}

# A second tenant's inputs reused in a management account: the given provider is ignored.
run "ci_roles_off_ignores_a_given_oidc_provider_arn" {
  command = plan

  variables {
    ci_roles             = false
    create_oidc_provider = false
    oidc_provider_arn    = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && output.oidc_provider_arn == null
    error_message = "With ci_roles = false a given oidc_provider_arn is ignored: nothing trusts it and the output is null."
  }
}

run "no_alternate_contacts_by_default" {
  command = plan

  assert {
    condition     = length(aws_account_alternate_contact.this) == 0
    error_message = "a workload account gets no alternate contacts unless asked"
  }
}

run "management_account_alternate_contacts" {
  command = plan
  variables {
    ci_roles = false
    alternate_contacts = {
      security = { name = "Fixture Owner", title = "Owner", email = "security@example.com", phone = "+64000000000" }
    }
  }

  assert {
    condition     = aws_account_alternate_contact.this["security"].alternate_contact_type == "SECURITY"
    error_message = "alternate contacts are set by type"
  }
}

run "alternate_contact_type_must_be_known" {
  command = plan
  variables {
    alternate_contacts = {
      finance = { name = "x", title = "x", email = "x@example.com", phone = "+64000000000" }
    }
  }
  expect_failures = [var.alternate_contacts]
}

run "budget_counts_spend_before_credits" {
  command = plan

  assert {
    condition     = aws_budgets_budget.account.cost_types[0].include_credit == false
    error_message = "the budget must leave credits out, or spend a credit pays for never alerts"
  }
}

run "multipart_abort_days_default_and_input" {
  command = plan

  assert {
    condition     = alltrue([for r in aws_s3_bucket_lifecycle_configuration.state.rule : r.abort_incomplete_multipart_upload[0].days_after_initiation == 1])
    error_message = "By default every lifecycle rule aborts incomplete uploads after 1 day."
  }
}

run "multipart_abort_days_follows_input" {
  command = plan

  variables {
    abort_incomplete_multipart_upload_days = 7
  }

  assert {
    condition = (
      length([for r in aws_s3_bucket_lifecycle_configuration.state.rule : r if r.id == "state-history" && r.abort_incomplete_multipart_upload[0].days_after_initiation == 7]) == 1 &&
      length([for r in aws_s3_bucket_lifecycle_configuration.state.rule : r if r.id == "plans-expire" && r.abort_incomplete_multipart_upload[0].days_after_initiation == 1]) == 1
    )
    error_message = "abort_incomplete_multipart_upload_days must set the state-history rule; the plans rule stays at 1 day."
  }
}

run "multipart_abort_days_rejects_zero" {
  command = plan

  variables {
    abort_incomplete_multipart_upload_days = 0
  }

  expect_failures = [var.abort_incomplete_multipart_upload_days]
}
