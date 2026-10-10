# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Derived from the terraform-aws plugin's bootstrap template. See NOTICE.txt.

# ------------------------------------------------------------------ account and repositories

variable "account_id" {
  description = "The 12-digit AWS account this bootstrap belongs to. The plan stops when the caller's credentials are for any other account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit string."
  }
}

variable "region" {
  description = "AWS Region for the state bucket, key and roles. There is no default; set it per deployment. The plan stops when the provider is set to another Region."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an AWS Region code such as the one in your deployment's tfvars."
  }
}

variable "github_repositories" {
  description = "Repositories the GitHub roles trust, each as <organisation>/<repository>. Every role trusts the exact subject of each one."
  type        = list(string)

  validation {
    condition     = length(var.github_repositories) > 0 && alltrue([for r in var.github_repositories : can(regex("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$", r))])
    error_message = "github_repositories must list at least one <organisation>/<repository>, with no wildcard."
  }

  validation {
    condition     = length(distinct(var.github_repositories)) == length(var.github_repositories)
    error_message = "github_repositories must not list a repository twice."
  }
}

variable "github_repository_ids" {
  description = "Numeric GitHub IDs of github_repositories, in the same order. When set, every role also requires the repository_id claim; names can be reused, IDs cannot."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.github_repository_ids : can(regex("^[0-9]+$", id))])
    error_message = "github_repository_ids must be numeric GitHub repository IDs."
  }

  validation {
    condition     = length(var.github_repository_ids) == 0 || length(var.github_repository_ids) == length(var.github_repositories)
    error_message = "github_repository_ids must be empty or give one ID for each entry of github_repositories."
  }
}

variable "github_subject_prefixes" {
  description = "The OIDC subject prefix GitHub reports for each of github_repositories, in the same order: `gh api repos/<organisation>/<repository>/actions/oidc/customization/sub --jq .sub_claim_prefix`. Repositories created after 2026-07-15 use the immutable form repo:<organisation>@<id>/<repository>@<id>; empty means repo:<organisation>/<repository> for every repository."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for p in var.github_subject_prefixes : can(regex("^repo:[A-Za-z0-9][A-Za-z0-9-]*(@[0-9]+)?/[A-Za-z0-9._-]+(@[0-9]+)?$", p))])
    error_message = "github_subject_prefixes must be exact prefixes such as repo:<organisation>/<repository> or repo:<organisation>@<id>/<repository>@<id>, with no wildcard."
  }

  validation {
    condition     = length(var.github_subject_prefixes) == 0 || length(var.github_subject_prefixes) == length(var.github_repositories)
    error_message = "github_subject_prefixes must be empty or give one prefix for each entry of github_repositories."
  }

  # A prefix trusts its own repository only: with the ids removed it must read the entry of github_repositories at
  # the same position, and it carries both ids or neither.
  validation {
    condition = alltrue([
      for i, p in var.github_subject_prefixes : try(join("/", regex("^repo:([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)$", p)),
      join("/", regex("^repo:([A-Za-z0-9][A-Za-z0-9-]*)@[0-9]+/([A-Za-z0-9._-]+)@[0-9]+$", p)), "") == try(var.github_repositories[i], "")
    ])
    error_message = "Each github_subject_prefixes entry must name the repository at the same position of github_repositories, with both names followed by @<numeric id> or neither."
  }
}

variable "github_owner_id" {
  description = "Numeric GitHub ID of the organisation or user that owns the repositories. When set, every role also requires the repository_owner_id claim."
  type        = string
  default     = null

  validation {
    condition     = var.github_owner_id == null ? true : can(regex("^[0-9]+$", var.github_owner_id))
    error_message = "github_owner_id must be a numeric GitHub owner ID."
  }
}

variable "default_branch" {
  description = "The repositories' default branch, read from the repository settings. Only the plan-default role trusts it."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.default_branch)) && !strcontains(var.default_branch, "*")
    error_message = "default_branch must be an exact branch name with no wildcard."
  }
}

variable "apply_workflow_refs" {
  description = "Per environment, the workflows allowed to use its apply role, as <organisation>/<repository>/.github/workflows/<file>@<ref>. An environment listed here also requires the job_workflow_ref claim; environments not listed do not."
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for e in keys(var.apply_workflow_refs) : contains(var.environments, e)])
    error_message = "apply_workflow_refs may name only entries of environments."
  }

  validation {
    condition = alltrue([for e, refs in var.apply_workflow_refs : length(refs) > 0 && alltrue([
      for r in refs : can(regex("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+/\\.github/workflows/[^@]+@.+$", r))
    ])])
    error_message = "Each apply_workflow_refs entry must list at least one <organisation>/<repository>/.github/workflows/<file>@<ref>."
  }
}

# ------------------------------------------------------------------ names and tags

variable "name_prefix" {
  description = "Prefix of the delivery role names (<prefix>-plan-pr, <prefix>-plan-default, <prefix>-apply-<environment>). Any value other than gha is also put in front of the boundary, key alias, budget, logging role and default bucket names. Each tenant in one account needs its own."
  type        = string
  default     = "gha"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.name_prefix))
    error_message = "name_prefix must be 2 to 12 lower-case letters or digits, starting with a letter, with no hyphen, so that one tenant's role/<prefix>-* pattern never matches another tenant's roles."
  }
}

variable "service" {
  description = "Short name used as the first part of resource names ('<service>-<environment>-<purpose>') and as the service tag."
  type        = string
  default     = "platform"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.service))
    error_message = "service must be 2 to 21 lower-case letters, digits or hyphens."
  }
}

variable "change_id" {
  description = "Four-digit change record number that this apply belongs to, written to the change tag. Leave null for no change tag."
  type        = string
  default     = null

  validation {
    condition     = var.change_id == null ? true : can(regex("^[0-9]{4}$", var.change_id))
    error_message = "change_id must be four digits, for example 0001, or null."
  }
}

variable "tags" {
  description = "Tags for every resource that takes tags, for example module.tags.common_tags. Keys are lower-case kebab-case. The module adds environment = shared, service, managed-by and change unless a key here already has the same name."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.tags) : can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", k))])
    error_message = "Each tag key must be lower-case kebab-case, for example cost-centre or managed-by."
  }
}

# ------------------------------------------------------------------ state bucket

variable "state_bucket_name" {
  description = "Name of the S3 bucket that holds Terraform state and saved plans. Null uses <account_id>-tfstate-<region>, the tenant convention, with <name_prefix>- before tfstate when name_prefix is not gha."
  type        = string
  default     = null

  validation {
    condition     = var.state_bucket_name == null ? true : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid S3 bucket name."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Days that replaced state versions are kept before they expire."
  type        = number
  default     = 90

  validation {
    condition     = var.noncurrent_version_expiration_days >= 30 && floor(var.noncurrent_version_expiration_days) == var.noncurrent_version_expiration_days
    error_message = "noncurrent_version_expiration_days must be a whole number of at least 30."
  }
}

variable "abort_incomplete_multipart_upload_days" {
  description = "Days after which an incomplete multipart upload under the state-history rule (the whole bucket) is aborted. The plans/ rule always aborts after 1 day."
  type        = number
  default     = 1

  validation {
    condition     = var.abort_incomplete_multipart_upload_days >= 1 && floor(var.abort_incomplete_multipart_upload_days) == var.abort_incomplete_multipart_upload_days
    error_message = "abort_incomplete_multipart_upload_days must be a whole number of at least 1."
  }
}

variable "plans_expiration_days" {
  description = "Days that saved plans under plans/ are kept. They hold sensitive values; keep this as short as release approval allows."
  type        = number
  default     = 7

  validation {
    condition     = var.plans_expiration_days >= 1 && var.plans_expiration_days <= 30 && floor(var.plans_expiration_days) == var.plans_expiration_days
    error_message = "plans_expiration_days must be a whole number from 1 to 30."
  }
}

# ------------------------------------------------------------------ budget

variable "budget_limit_usd" {
  description = "Monthly cost budget for this account in US dollars. Notifications go out at 80% and 100% of actual cost, and when the forecast passes 100%."
  type        = number

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be greater than zero."
  }
}

variable "notification_email" {
  description = "Email address of the budget owner who receives the budget notifications."
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.notification_email))
    error_message = "notification_email must be an email address."
  }
}

# ------------------------------------------------------------------ environments

variable "environments" {
  description = "Environments deployed into this account. Each gets an apply role that trusts only its GitHub Environment. Names follow the workload roots: 2 to 12 lower-case letters or digits, starting with a letter."
  type        = list(string)
  default     = ["dev", "production"]

  validation {
    condition     = length(var.environments) > 0 && alltrue([for e in var.environments : can(regex("^[a-z][a-z0-9]{1,11}$", e))])
    error_message = "environments must be a non-empty list of names of 2 to 12 lower-case letters or digits, starting with a letter, the same rule as the environment variable of the workload roots."
  }
}

variable "production_environments" {
  description = "The entries of environments that are production. In single-account mode every other environment's apply role and workload boundary are denied their resources (by tag and by name), their state and the saved plans. Only their apply roles read saved plans. The delivery workflows use the name production."
  type        = list(string)
  default     = ["production"]

  validation {
    condition     = alltrue([for p in var.production_environments : contains(var.environments, p)])
    error_message = "production_environments must list only names from environments. In an account that holds no production environment (one account per environment), set it to []."
  }

  validation {
    condition     = var.account_mode != "single" || length(var.production_environments) > 0
    error_message = "In single-account mode production_environments must name at least one environment; otherwise nothing keeps the other environments away from production."
  }

  validation {
    condition     = !contains(var.environments, "production") || contains(var.production_environments, "production")
    error_message = "An environment named production must be listed in production_environments."
  }
}

variable "account_mode" {
  description = "single: one account holds every environment, so every environment outside production_environments is denied production resources. landing-zone: one account per environment."
  type        = string
  default     = "single"

  validation {
    condition     = contains(["single", "landing-zone"], var.account_mode)
    error_message = "account_mode must be single or landing-zone."
  }
}

# ------------------------------------------------------------------ roles

variable "service_role_path" {
  description = "IAM path under which apply roles may create workload roles, as /<path>/<environment>/. Each tenant in one account needs its own."
  type        = string
  default     = "workload"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.service_role_path))
    error_message = "service_role_path must be a single lower-case path segment."
  }
}

variable "apply_policy_arns" {
  description = "Managed policies attached to every apply role. Null attaches PowerUserAccess. The inline denies apply either way."
  type        = list(string)
  default     = null

  validation {
    condition = var.apply_policy_arns == null ? true : length(var.apply_policy_arns) > 0 && alltrue([
      for a in var.apply_policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+$", a))
    ])
    error_message = "apply_policy_arns must be null or a non-empty list of IAM managed policy ARNs."
  }
}

variable "max_session_duration" {
  description = "Maximum session length in seconds for every role this module creates."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200 && floor(var.max_session_duration) == var.max_session_duration
    error_message = "max_session_duration must be a whole number of seconds from 3600 (1 hour) to 43200 (12 hours)."
  }
}

# ------------------------------------------------------------------ once per account and Region

variable "ci_roles" {
  description = "Create the GitHub OIDC trust and the plan and apply roles. Turn it off in an organization's management account: a person applies the landing zone there, so the account needs its state bucket, key and budget only."
  type        = bool
  default     = true
}

variable "create_oidc_provider" {
  description = "Create the account's GitHub OIDC provider. An account holds only one; a second tenant in the same account sets false and passes oidc_provider_arn. Ignored with ci_roles = false."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of the account's existing GitHub OIDC provider. Required when create_oidc_provider = false, and refused otherwise. Ignored with ci_roles = false."
  type        = string
  default     = null

  validation {
    # With ci_roles = false the module trusts no provider, so none is required.
    condition = !var.ci_roles || (
      var.create_oidc_provider ? var.oidc_provider_arn == null :
      can(regex("^arn:aws[a-z-]*:iam::${var.account_id}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    )
    error_message = "With create_oidc_provider = false, set oidc_provider_arn to this account's GitHub provider, arn:<partition>:iam::<account_id>:oidc-provider/token.actions.githubusercontent.com. With create_oidc_provider = true, leave it null."
  }
}

variable "enable_api_gateway_account" {
  description = "Sets the account's API Gateway logging role in this Region. REST API stages cannot write access or execution logs without it. Set false when another stack in this account and Region already manages the setting, such as a second tenant's bootstrap."
  type        = bool
  default     = true
}

variable "break_glass_user" {
  type        = bool
  description = "Create the break-glass IAM user (administrator, no access key, MFA required) in an organization's management account. The owner adds its password and MFA in the console after the apply; Terraform never holds either. A user the owner already made in the console is adopted with import blocks in the calling root, to aws_iam_user.break_glass[0], aws_iam_user_policy_attachment.break_glass_admin[0] and aws_iam_user_policy.break_glass_require_mfa[0]."
  default     = false
}

variable "break_glass_path" {
  type        = string
  description = "IAM path of the break-glass user. A user created in the console has the path /; keep it when importing so the import changes nothing."
  default     = "/break-glass/"

  validation {
    condition     = can(regex("^/([A-Za-z0-9+=,.@_-]+/)*$", var.break_glass_path))
    error_message = "break_glass_path must start and end with /, for example / or /break-glass/."
  }
}

variable "protect_security_baseline" {
  type        = bool
  description = "Add the security baseline deny statements to every workload boundary: its alerts topic and rules, trail log group, account-level logs policies, the account S3 public access block and the SecurityBaseline metric namespace stay as the person who applied the baseline left them. false leaves them out."
  default     = true
}

variable "security_baseline_prefix" {
  type        = string
  description = "name_prefix the security baseline was applied with; its topic, rules and log groups are named <prefix>-*. Used only with protect_security_baseline = true."
  default     = "security-baseline"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.security_baseline_prefix))
    error_message = "security_baseline_prefix must be 2 to 31 lower-case letters, digits or hyphens, starting with a letter."
  }
}

variable "alternate_contacts" {
  type = map(object({
    name  = string
    title = string
    email = string
    phone = string
  }))
  description = "The account's alternate contacts, keyed by billing, operations or security."
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.alternate_contacts) : contains(["billing", "operations", "security"], k)])
    error_message = "alternate_contacts keys must be billing, operations or security."
  }
}

variable "create_state_kms_key" {
  description = "true (the default) encrypts state and saved plans with a customer-managed key, about 1 USD a month: its policy is yours, every use is in CloudTrail, and the bucket policy refuses any other key. false uses the bucket default SSE-S3 (AES-256): no key, no cost, still encrypted at rest and reachable only over TLS 1.2 or later; backend_settings.kms_key_id is then null."
  type        = bool
  default     = true
}
