# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.

variable "account_id" {
  description = "The account: for an Organizations member, as the organization lists it: aws organizations list-accounts. The calling root's provider assumes a role in this account and sets allowed_account_ids to it."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be the member account's 12-digit ID."
  }
}

variable "require_account_workspace" {
  description = "Stop a plan unless the selected workspace is named after account_id, so each member account's state sits under its own key. Only the plan-only tests, which run in the default workspace, set it to false."
  type        = bool
  default     = true
}

variable "region" {
  description = "The member account's Region. Set it to the Region of the calling root's provider. There is no default."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an AWS Region such as ap-southeast-2."
  }
}

variable "github_repositories" {
  description = "<organisation>/<repository> of each repository whose pipelines deploy into this account. Required with ci_platform = github."
  type        = list(string)
  default     = []

  validation {
    condition     = var.ci_platform != "azure-devops" || length(var.github_repositories) == 0
    error_message = "github_repositories is a GitHub input; leave it empty with ci_platform = azure-devops."
  }
  validation {
    condition     = alltrue([for r in var.github_repositories : can(regex("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$", r))])
    error_message = "each github_repositories entry must be <organisation>/<repository> with no wildcard."
  }
}

variable "github_repository_ids" {
  description = "Numeric ID of each repository, in the same order: gh api repos/<organisation>/<repository> --jq .id."
  type        = list(string)
  default     = []
}

variable "github_subject_prefixes" {
  description = "Each repository's OIDC subject prefix, in the same order, read from its settings and never assumed: gh api repos/<organisation>/<repository>/actions/oidc/customization/sub --jq .sub_claim_prefix."
  type        = list(string)
  default     = []
}

variable "github_owner_id" {
  description = "Numeric ID of the repositories' owner: gh api orgs/<organisation> --jq .id."
  type        = string
  default     = null
}

variable "default_branch" {
  description = "The repositories' default branch, read from the repository settings."
  type        = string
}

variable "apply_workflow_refs" {
  description = "Per environment, the only workflows allowed to apply: <organisation>/<repository>/.github/workflows/<file>@<ref>."
  type        = map(list(string))
  default     = {}
}

variable "budget_limit_usd" {
  description = "Monthly budget in US dollars, set by the budget owner. Alerts at 80% and 100% of actual cost and on a forecast over 100%; credits are left out."
  type        = number

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd is the budget owner's figure; 0 is refused, so an unedited copy of the example never applies."
  }
}

variable "notification_email" {
  description = "The watched mailbox for budget alerts (kept in the caller's untracked environment, never in a tracked file)."
  type        = string
}

variable "change_id" {
  description = "The change record this apply belongs to, four digits, written to the change tag."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{4}$", var.change_id))
    error_message = "change_id is a four-digit change record, for example 0037."
  }
}

variable "service" {
  description = "Short name that starts resource names and fills the service tag."
  type        = string
  default     = "platform"
}

variable "account_mode" {
  description = "single: this account holds every environment (a workload account); landing-zone: one account per environment (a sandbox)."
  type        = string
}

variable "environments" {
  description = "The environments this account holds; each gets an apply role that trusts only its GitHub Environment."
  type        = list(string)
}

variable "production_environments" {
  description = "The entries of environments that are production; [] for an account that holds none (account_mode = landing-zone)."
  type        = list(string)

  validation {
    condition     = var.account_mode != "single" || length(var.production_environments) > 0
    error_message = "With account_mode = single, production_environments must name at least one environment: in one account, nothing else keeps dev away from production."
  }

  validation {
    condition     = !var.security_baseline || length(var.production_environments) > 0
    error_message = "With security_baseline = true, production_environments must name at least one environment: the baseline's deny of developer roles against production's resources needs one."
  }
}

variable "create_state_kms_key" {
  description = "true: the account's state bucket gets a customer-managed KMS key (about 1 USD a month: key policy as a second lock, a CloudTrail line per decrypt, one-edit revocation). false: SSE-S3, no key and no cost. The default is the key, the stricter choice."
  type        = bool
  default     = true
}

variable "allowed_regions" {
  description = "The Regions member accounts may use. The default VPCs are removed in these Regions only; the Region policy blocks the others."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for r in var.allowed_regions : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", r))])
    error_message = "allowed_regions are AWS Regions such as ap-southeast-2."
  }
}

variable "management_account_id" {
  description = "The organization's management account, an input of the caller. It is read only to refuse removing default VPCs there."
  type        = string
  default     = null
}

variable "default_vpcs" {
  description = "What Terraform does with the default VPC in each allowed Region. keep: manages none and never deletes (the default; the caller must refuse it once any was adopted). adopt: manages each one with force_destroy, nothing is deleted yet. remove: manages none, so the plan shows each adopted default VPC destroyed (adopt first, then remove; see default-vpcs.tf). adopt and remove are refused in the management account."
  type        = string
  default     = "keep"

  validation {
    condition     = contains(["keep", "adopt", "remove"], var.default_vpcs)
    error_message = "default_vpcs is keep, adopt or remove."
  }
  validation {
    condition     = var.default_vpcs == "keep" || length(var.allowed_regions) > 0
    error_message = "default_vpcs adopt or remove needs allowed_regions, so only Regions the caller allows are touched."
  }
  validation {
    condition     = var.default_vpcs == "keep" || (var.management_account_id != null && var.account_id != var.management_account_id)
    error_message = "default_vpcs adopt or remove is refused in the management account, and needs management_account_id (management_account_id) to know which that is."
  }
}

variable "tags" {
  description = "Cost tags on every resource, for example service, environment and change."
  type        = map(string)
  default     = {}
}

variable "lambda_concurrency_quota" {
  type        = number
  default     = 0
  description = "Requested Lambda concurrent-executions quota . 0 requests nothing; otherwise 1000 to 20000. A request is one-way: destroy does not lower it. While AWS reviews it, re-plans show a change. Set it only on a new account or after AWS grants it, then it reads the granted value and makes no second request."

  validation {
    condition     = var.lambda_concurrency_quota == 0 || (var.lambda_concurrency_quota >= 1000 && var.lambda_concurrency_quota <= 20000)
    error_message = "lambda_concurrency_quota is 0 (no request) or between 1000 and 20000."
  }
}

variable "resource_explorer" {
  type        = bool
  default     = false
  description = "Create an AWS Resource Explorer LOCAL index in each allowed Region . Off by default. Needs allowed_regions."

  validation {
    condition     = !var.resource_explorer || length(var.allowed_regions) > 0
    error_message = "resource_explorer needs allowed_regions, so only Regions the caller allows are indexed."
  }
}

variable "github_owner_ids" {
  type        = list(string)
  default     = []
  description = "Numeric owner IDs of github_repositories, in the same order, when more than one organisation owns them. Not together with github_owner_id."
}

variable "workload_boundary_extra_actions" {
  type        = map(list(string))
  default     = {}
  description = "Per environment, extra enumerated read actions added to that environment's workload boundary."
}

variable "passrole_services" {
  type        = list(string)
  default     = []
  description = "Extra service principals (for example bedrock-agentcore.amazonaws.com) the apply roles may pass workload roles to."
}

variable "container_repositories" {
  type        = list(string)
  default     = []
  description = "Names of container image registries (ECR) to create in this account. Empty creates none."
}

variable "ci_platform" {
  type        = string
  description = "The pipeline platform the roles trust: github (default) or azure-devops. See the bootstrap module."
  default     = "github"
}

variable "ado_organization_id" {
  type        = string
  description = "Azure DevOps organization GUID (lower-case). Only with ci_platform = azure-devops."
  default     = null
}

variable "ado_organization_name" {
  type        = string
  description = "Azure DevOps organization name, the first segment of the subject sc://<organization>/<project>/<connection>. Only with ci_platform = azure-devops."
  default     = null
}

variable "ado_plan_service_connections" {
  type = list(object({
    project = string
    name    = string
  }))
  description = "Service connections the plan roles trust, each { project, name }. Only with ci_platform = azure-devops."
  default     = []
}

variable "ado_apply_service_connections" {
  type = map(list(object({
    project = string
    name    = string
  })))
  description = "Per environment, the service connections its apply role trusts. Only with ci_platform = azure-devops."
  default     = {}
}

variable "name_prefix" {
  type        = string
  description = "Prefix of the delivery role names (<prefix>-plan-pr, <prefix>-plan-default, <prefix>-apply-<environment>). Any value other than gha is also put in front of the boundary, budget and state bucket names, so a second tenant in one account never collides with the first."
  default     = "gha"
}

variable "state_bucket_name" {
  type        = string
  description = "Name of the state bucket. Null uses <account_id>-tfstate-<region> (with the name_prefix in front of tfstate when it is not gha)."
  default     = null
}

variable "existing_oidc_provider_arn" {
  type        = string
  description = "ARN of the account's OIDC provider for the ci_platform issuer when it already has one (an account holds only one). Null creates it."
  default     = null

  validation {
    condition     = var.existing_oidc_provider_arn == null || can(regex(var.ci_platform == "azure-devops" ? "^arn:aws[a-z-]*:iam::${var.account_id}:oidc-provider/vstoken\\.dev\\.azure\\.com/${coalesce(var.ado_organization_id, "none")}$" : "^arn:aws[a-z-]*:iam::${var.account_id}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", coalesce(var.existing_oidc_provider_arn, "-")))
    error_message = "existing_oidc_provider_arn must be this account's provider, arn:<partition>:iam::<account_id>:oidc-provider/token.actions.githubusercontent.com (github) or .../vstoken.dev.azure.com/<organization GUID> (azure-devops)."
  }
}

variable "enable_api_gateway_account" {
  type        = bool
  description = "Set the account's API Gateway logging role in this Region. Set false when another stack in this account and Region already manages it."
  default     = true
}

variable "security_baseline" {
  type        = bool
  description = "Also apply the account's security baseline (modules/security-baseline): audit trail, alarms, IAM password policy, S3 public access block, EBS encryption and IMDSv2 by default. Required, so a caller states it: true for a standalone account (the former account-baseline), false for an Organizations member, which gets these from the organization."
}

variable "security_name_prefix" {
  type        = string
  description = "Prefix of the security baseline's own resources (trail, buckets, alerts topic). The delivery roles are denied changes to everything it names. Used only with security_baseline = true."
  default     = "security-baseline-shared"
}

variable "alert_email" {
  type        = string
  description = "Address that receives the security alarms (AWS sends a confirmation first). Null uses notification_email. Used only with security_baseline = true."
  default     = null

  validation {
    condition     = var.alert_email == null || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", coalesce(var.alert_email, "-")))
    error_message = "alert_email must be an email address."
  }
}

variable "access_analyzer_enabled" {
  type        = bool
  description = "Create the account's IAM Access Analyzer. An account may hold only one per Region: set false when it already has one. Used only with security_baseline = true."
  default     = true
}

variable "security_kms_key_enabled" {
  type        = bool
  description = "Create the security baseline's customer-managed key. It costs $1.00 per key version per month plus requests. False encrypts the trail bucket with S3-managed keys and creates no key. Used only with security_baseline = true."
  default     = true
}

variable "access_log_bucket_enabled" {
  type        = bool
  description = "Create the second bucket that receives the trail bucket's S3 server access logs. It costs S3 storage and requests for as long as the logs are kept. Used only with security_baseline = true."
  default     = true
}

variable "log_retention_days" {
  type        = number
  description = "Days the trail keeps its log files and log events: 90, 400 or longer. Used only with security_baseline = true."
  default     = 400
}
