# Plan-only tests with a mocked AWS provider: no credentials, no real resources. The bootstrap module's own runs live
# in modules/bootstrap/tests; these assert only what this module adds. Account 444455556666 is the member account and
# 111122223333 the management account. terraform test runs in the default workspace, so the workspace rule is off
# except where a run proves it.
mock_provider "aws" {
  override_during = plan

  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "444455556666" }
  }
  mock_data "aws_region" {
    defaults = { region = "ap-southeast-2" }
  }
  mock_data "aws_vpc" {
    defaults = { id = "vpc-00000000000000001" }
  }
  mock_data "aws_subnets" {
    defaults = { ids = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"] }
  }
  mock_data "aws_subnet" {
    defaults = { availability_zone = "ap-southeast-2a" }
  }
  mock_data "aws_organizations_organization" {
    defaults = { master_account_id = "111122223333" }
  }
  mock_data "aws_internet_gateway" {
    defaults = { internet_gateway_id = "igw-00000000000000001" }
  }
  # The default VPC's gateway is imported; the mock plants the state the import reads.
  mock_resource "aws_internet_gateway" {
    defaults = {
      id       = "igw-00000000000000001"
      vpc_id   = "vpc-00000000000000001"
      arn      = "arn:aws:ec2:ap-southeast-2:444455556666:internet-gateway/igw-00000000000000001"
      owner_id = "444455556666"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn    = "arn:aws:kms:ap-southeast-2:444455556666:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::444455556666:oidc-provider/token.actions.githubusercontent.com" }
  }
}

variables {
  account_id              = "444455556666"
  region                  = "ap-southeast-2"
  github_repositories     = ["acme/platform"]
  github_repository_ids   = ["123456789"]
  github_subject_prefixes = ["repo:acme@987654/platform@123456789"]
  github_owner_id         = "987654"
  default_branch          = "develop"
  budget_limit_usd        = 100
  notification_email      = "finance@example.com"
  change_id               = "0037"
  security_baseline       = false
  tags                    = { service = "platform", change = "0037" }

  require_account_workspace = false
}

run "workload_plans_dev_and_production" {
  command = plan

  variables {
    account_mode            = "single"
    environments            = ["dev", "production"]
    production_environments = ["production"]
    apply_workflow_refs     = { production = ["acme/platform/.github/workflows/release.yml@refs/heads/develop"] }
  }

  assert {
    condition     = join(",", sort(keys(output.apply_role_arns))) == "dev,production" && length(output.workload_boundary_policy_arns) == 2
    error_message = "the Workload account gets an apply role and a permissions boundary for each of dev and production"
  }
  assert {
    condition     = length(output.plan_role_arns) == 2 && join(",", module.bootstrap.plan_role_names) == "gha-plan-pr,gha-plan-default"
    error_message = "the Workload account gets the two read-only plan roles that price every change"
  }
  assert {
    condition     = output.budget_name == "platform-shared-monthly-cost"
    error_message = "the Workload account gets its monthly budget"
  }
  assert {
    condition     = output.account_id == "444455556666"
    error_message = "the plan runs in the member account"
  }
}

run "sandbox_plans_one_environment_and_no_production_role" {
  command = plan

  variables {
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }

  assert {
    condition     = keys(output.apply_role_arns) == ["sandbox"] && length(output.plan_role_arns) == 2
    error_message = "the Sandbox gets one apply role, for its own environment, and no production role"
  }
  assert {
    condition     = output.budget_name == "platform-shared-monthly-cost" && module.bootstrap.break_glass_user_arn == null
    error_message = "the Sandbox gets its monthly budget and no IAM user"
  }
}

run "a_session_in_another_account_stops_the_plan" {
  command = plan

  variables {
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  override_data {
    target = data.aws_caller_identity.current
    values = { account_id = "111122223333" }
  }
  expect_failures = [data.aws_caller_identity.current]
}

run "an_unedited_budget_is_refused" {
  command = plan

  variables {
    budget_limit_usd        = 0
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  expect_failures = [var.budget_limit_usd]
}

run "a_placeholder_account_is_refused" {
  command = plan

  variables {
    account_id              = "<the account LZ_SANDBOX_ACCOUNT names>"
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  expect_failures = [var.account_id]
}

run "a_workspace_not_named_after_the_account_is_refused" {
  command = plan

  variables {
    require_account_workspace = true
    account_mode              = "landing-zone"
    environments              = ["sandbox"]
    production_environments   = []
  }
  expect_failures = [data.aws_caller_identity.current]
}

run "the_key_is_kept_by_default_for_an_enterprise_tenant" {
  command = plan

  variables {
    account_mode            = "single"
    environments            = ["dev", "production"]
    production_environments = ["production"]
    apply_workflow_refs     = { production = ["acme/platform/.github/workflows/release.yml@refs/heads/develop"] }
  }
  assert {
    condition     = var.create_state_kms_key && output.backend_settings.kms_key_id == "arn:aws:kms:ap-southeast-2:444455556666:key/00000000-0000-0000-0000-000000000000"
    error_message = "with create_state_kms_key true (the default) the account's backend settings name the state key"
  }
}

run "a_startup_tenant_gets_no_key" {
  command = plan

  variables {
    create_state_kms_key    = false
    account_mode            = "single"
    environments            = ["dev", "production"]
    production_environments = ["production"]
    apply_workflow_refs     = { production = ["acme/platform/.github/workflows/release.yml@refs/heads/develop"] }
  }
  assert {
    condition     = output.backend_settings.kms_key_id == null && output.backend_settings.encrypt == true
    error_message = "with create_state_kms_key false the backend settings carry no key and still say encrypt = true (SSE-S3)"
  }
  assert {
    condition     = length(output.apply_role_arns) == 2 && output.budget_name == "platform-shared-monthly-cost"
    error_message = "choosing no state key changes nothing else in the account's bootstrap"
  }
}

run "default_vpcs_are_kept_by_default" {
  command = plan

  variables {
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
    allowed_regions         = ["ap-southeast-2", "ap-southeast-6"]
  }
  assert {
    condition     = var.default_vpcs == "keep" && length(aws_default_vpc.this) == 0 && length(aws_default_subnet.this) == 0 && length(aws_internet_gateway.this) == 0
    error_message = "with default_vpcs keep (the default) the root declares no default VPC resource"
  }
}

run "adopting_default_vpcs_manages_one_per_allowed_region_with_force_destroy" {
  command = plan

  # A mocked provider cannot import: the imported gateway's state is planted.
  override_resource {
    target = aws_internet_gateway.this
    values = {
      id       = "igw-00000000000000001"
      vpc_id   = "vpc-00000000000000001"
      arn      = "arn:aws:ec2:ap-southeast-2:444455556666:internet-gateway/igw-00000000000000001"
      owner_id = "444455556666"
      region   = "ap-southeast-2"
      tags     = { Name = "default-igw" }
      tags_all = { Name = "default-igw" }
    }
  }


  variables {
    default_vpcs            = "adopt"
    management_account_id   = "111122223333"
    allowed_regions         = ["ap-southeast-2", "ap-southeast-6"]
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  assert {
    condition     = join(",", sort(keys(aws_default_vpc.this))) == "ap-southeast-2,ap-southeast-6"
    error_message = "one default VPC is managed per allowed Region, and no other Region"
  }
  assert {
    condition     = alltrue([for r, v in aws_default_vpc.this : v.force_destroy && v.region == r])
    error_message = "each default VPC is managed in its own Region with force_destroy, so moving to remove deletes it"
  }
}

run "adopting_default_vpcs_also_adopts_every_default_subnet_and_the_internet_gateway" {
  command = plan

  # A mocked provider cannot import: the imported gateway's state is planted.
  override_resource {
    target = aws_internet_gateway.this
    values = {
      id       = "igw-00000000000000001"
      vpc_id   = "vpc-00000000000000001"
      arn      = "arn:aws:ec2:ap-southeast-2:444455556666:internet-gateway/igw-00000000000000001"
      owner_id = "444455556666"
      region   = "ap-southeast-2"
      tags     = { Name = "default-igw" }
      tags_all = { Name = "default-igw" }
    }
  }


  variables {
    default_vpcs            = "adopt"
    management_account_id   = "111122223333"
    allowed_regions         = ["ap-southeast-2", "ap-southeast-6"]
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  assert {
    condition     = length(aws_default_subnet.this) == 6 && alltrue([for k, v in aws_default_subnet.this : v.force_destroy && startswith(k, v.region)])
    error_message = "every default subnet of each allowed Region is adopted in its own Region with force_destroy"
  }
  assert {
    condition     = join(",", sort(keys(aws_internet_gateway.this))) == "ap-southeast-2,ap-southeast-6"
    error_message = "one internet gateway per allowed Region is adopted (imported), in that Region"
  }
}

run "removing_default_vpcs_declares_none_so_the_plan_shows_the_deletes" {
  command = plan

  variables {
    default_vpcs            = "remove"
    management_account_id   = "111122223333"
    allowed_regions         = ["ap-southeast-2", "ap-southeast-6"]
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  assert {
    condition     = length(aws_default_vpc.this) == 0 && length(aws_default_subnet.this) == 0 && length(aws_internet_gateway.this) == 0
    error_message = "remove declares no default VPC, subnet or gateway resource: the adopted ones in state are planned for destruction"
  }
}

run "default_vpcs_value_must_be_keep_adopt_or_remove" {
  command = plan

  variables {
    default_vpcs            = "true"
    management_account_id   = "111122223333"
    allowed_regions         = ["ap-southeast-2"]
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  expect_failures = [var.default_vpcs]
}

run "default_vpcs_adopt_is_refused_in_the_management_account" {
  command = plan

  variables {
    default_vpcs            = "adopt"
    management_account_id   = "444455556666"
    allowed_regions         = ["ap-southeast-2"]
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  expect_failures = [var.default_vpcs]
}

run "default_vpcs_remove_is_refused_in_the_management_account" {
  command = plan

  variables {
    default_vpcs            = "remove"
    management_account_id   = "444455556666"
    allowed_regions         = ["ap-southeast-2"]
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  expect_failures = [var.default_vpcs]
}

run "default_vpcs_adopt_needs_the_allowed_regions" {
  command = plan

  variables {
    default_vpcs            = "adopt"
    management_account_id   = "111122223333"
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  expect_failures = [var.default_vpcs]
}

# Lambda concurrency quota and Resource Explorer (change 0064).
run "no_lambda_quota_request_by_default" {
  command = plan
  variables {
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  assert {
    condition     = length(aws_servicequotas_service_quota.lambda_concurrency) == 0
    error_message = "no quota request unless the tenant sets lambda_concurrency_quota"
  }
}

run "lambda_quota_1000_plans_one_request" {
  command = plan
  variables {
    account_mode             = "landing-zone"
    environments             = ["sandbox"]
    production_environments  = []
    lambda_concurrency_quota = 1000
  }
  assert {
    condition     = length(aws_servicequotas_service_quota.lambda_concurrency) == 1
    error_message = "one quota request"
  }
  assert {
    condition     = aws_servicequotas_service_quota.lambda_concurrency[0].service_code == "lambda" && aws_servicequotas_service_quota.lambda_concurrency[0].quota_code == "L-B99A9384" && aws_servicequotas_service_quota.lambda_concurrency[0].region == "ap-southeast-2" && aws_servicequotas_service_quota.lambda_concurrency[0].value == 1000
    error_message = "lambda, L-B99A9384, the member Region, value 1000"
  }
}

run "lambda_quota_500_is_refused" {
  command = plan
  variables {
    account_mode             = "landing-zone"
    environments             = ["sandbox"]
    production_environments  = []
    lambda_concurrency_quota = 500
  }
  expect_failures = [var.lambda_concurrency_quota]
}

run "lambda_quota_50000_is_refused" {
  command = plan
  variables {
    account_mode             = "landing-zone"
    environments             = ["sandbox"]
    production_environments  = []
    lambda_concurrency_quota = 50000
  }
  expect_failures = [var.lambda_concurrency_quota]
}

run "resource_explorer_is_off_by_default" {
  command = plan
  variables {
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  assert {
    condition     = length(aws_resourceexplorer2_index.local) == 0
    error_message = "no index unless the tenant asks"
  }
}

run "resource_explorer_plans_one_local_index_per_allowed_region" {
  command = plan
  variables {
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
    resource_explorer       = true
    allowed_regions         = ["ap-southeast-2", "us-east-1"]
  }
  assert {
    condition     = length(aws_resourceexplorer2_index.local) == 2 && alltrue([for k, i in aws_resourceexplorer2_index.local : i.type == "LOCAL" && i.region == k])
    error_message = "one LOCAL index in each allowed Region"
  }
}

run "resource_explorer_needs_allowed_regions" {
  command = plan
  variables {
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
    resource_explorer       = true
  }
  expect_failures = [var.resource_explorer]
}

run "adopting_exposes_the_default_igw_ids_for_the_callers_import" {
  command = plan

  override_resource {
    target = aws_internet_gateway.this
    values = {
      id       = "igw-00000000000000001"
      vpc_id   = "vpc-00000000000000001"
      arn      = "arn:aws:ec2:ap-southeast-2:444455556666:internet-gateway/igw-00000000000000001"
      owner_id = "444455556666"
      region   = "ap-southeast-2"
      tags     = { Name = "default-igw" }
      tags_all = { Name = "default-igw" }
    }
  }

  variables {
    default_vpcs            = "adopt"
    management_account_id   = "111122223333"
    allowed_regions         = ["ap-southeast-2"]
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  assert {
    condition     = keys(output.default_igw_ids) == ["ap-southeast-2"] && output.default_igw_ids["ap-southeast-2"] == "igw-00000000000000001"
    error_message = "default_igw_ids carries one gateway ID per allowed Region, for the caller's import block"
  }
}

run "default_igw_ids_is_empty_unless_adopting" {
  command = plan

  variables {
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
    allowed_regions         = ["ap-southeast-2"]
  }
  assert {
    condition     = length(output.default_igw_ids) == 0
    error_message = "with default_vpcs keep there is nothing to import"
  }
}

run "default_vpcs_remove_is_refused_when_the_organization_says_this_is_the_management_account" {
  command = plan
  variables {
    default_vpcs            = "remove"
    management_account_id   = "111122223333"
    allowed_regions         = ["ap-southeast-2"]
    account_mode            = "landing-zone"
    environments            = ["sandbox"]
    production_environments = []
  }
  override_data {
    target = data.aws_organizations_organization.this[0]
    values = { master_account_id = "444455556666" }
  }
  expect_failures = [terraform_data.management_account_guard]
}

run "the_release_one_inputs_reach_bootstrap" {
  command = plan

  variables {
    account_mode            = "single"
    environments            = ["dev", "production"]
    production_environments = ["production"]
    github_repositories     = ["acme/platform", "other/app"]
    github_repository_ids   = []
    github_subject_prefixes = []
    github_owner_id         = null
    github_owner_ids        = ["1001", "2002"]

    workload_boundary_extra_actions = { dev = ["bedrock:GetAgent"] }
    passrole_services               = ["bedrock-agentcore.amazonaws.com"]
    container_repositories          = ["shop-api"]
  }

  assert {
    condition     = jsondecode(output.policy_documents.trust["gha-plan-pr"]).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:repository_owner_id"] == ["1001", "2002"]
    error_message = "github_owner_ids reaches the trust"
  }

  assert {
    condition     = contains(flatten([for s in jsondecode(output.policy_documents.boundary["dev"]).Statement : s.Action if s.Sid == "WorkloadExtraReads"]), "bedrock:GetAgent")
    error_message = "workload_boundary_extra_actions reaches dev's boundary"
  }

  assert {
    condition     = contains([for s in jsondecode(output.policy_documents.workload_iam["dev"]).Statement : s.Condition.StringEquals["iam:PassedToService"] if s.Sid == "PassWorkloadRoles"][0], "bedrock-agentcore.amazonaws.com")
    error_message = "passrole_services reaches the PassRole condition"
  }

  assert {
    condition     = keys(output.container_repository_urls) == ["shop-api"]
    error_message = "container_repositories reaches bootstrap, which creates the registry"
  }
}

run "a_member_keeps_the_security_baseline_deny_without_the_baseline_module" {
  command = plan

  variables {
    account_mode            = "single"
    environments            = ["dev", "production"]
    production_environments = ["production"]
  }

  assert {
    condition     = length(module.security) == 0
    error_message = "security_baseline false plans no security-baseline module in a member account"
  }

  assert {
    condition     = strcontains(jsonencode(output.policy_documents.boundary), "ProtectSecurityBaseline") && strcontains(jsonencode(output.policy_documents.boundary), "security-baseline-*")
    error_message = "the workload boundary still denies changes to the organization's security baseline (default prefix security-baseline), whether or not this module applies it"
  }
}
