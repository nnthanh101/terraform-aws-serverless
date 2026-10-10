# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# The inputs of one account's baseline. Six are required; the rest have defaults that suit one account holding dev and
# production. Each is checked again by the submodule that uses it.

variable "account_id" {
  type        = string
  description = "The 12-digit AWS account this baseline belongs to. The plan stops when the provider signs in to any other account."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  type        = string
  description = "The account's home Region: the state bucket, the trail, the alarms and the per-Region defaults live here. There is no default."

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an AWS Region code such as ap-southeast-2."
  }
}

variable "github_repository" {
  type        = string
  description = "The one GitHub repository the plan and apply roles trust, as <organisation>/<repository>. Change this one value to point the account at another repository."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$", var.github_repository))
    error_message = "github_repository must be <organisation>/<repository> with no wildcard."
  }
}

variable "default_branch" {
  type        = string
  description = "The repository's default branch. Only the plan role for the default branch trusts it."

  validation {
    condition     = can(regex("^[A-Za-z0-9._/-]+$", var.default_branch)) && !strcontains(var.default_branch, "*")
    error_message = "default_branch must be an exact branch name with no wildcard."
  }
}

variable "budget_limit_usd" {
  type        = number
  description = "Monthly cost budget for the account in US dollars. Emails go out at 80% and 100% of actual cost, and when the forecast passes 100%."

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be greater than zero."
  }
}

variable "notification_email" {
  type        = string
  description = "Address that receives the budget messages."

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.notification_email))
    error_message = "notification_email must be an email address."
  }
}

variable "alert_email" {
  type        = string
  description = "Address that receives the security alarms (AWS sends a confirmation first). Null uses notification_email."
  default     = null

  validation {
    condition     = var.alert_email == null || can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", coalesce(var.alert_email, "-")))
    error_message = "alert_email must be an email address."
  }
}

variable "github_repository_id" {
  type        = string
  description = "Numeric id of github_repository (gh api repos/<org>/<repo> --jq .id). When set, the roles also require it, so a renamed or re-created repository cannot reuse the trust."
  default     = null

  validation {
    condition     = var.github_repository_id == null || can(regex("^[0-9]+$", coalesce(var.github_repository_id, "-")))
    error_message = "github_repository_id must be a numeric GitHub repository id."
  }
}

variable "github_owner_id" {
  type        = string
  description = "Numeric id of the repository's owner (gh api users/<org> --jq .id). When set, the roles also require it."
  default     = null

  validation {
    condition     = var.github_owner_id == null || can(regex("^[0-9]+$", coalesce(var.github_owner_id, "-")))
    error_message = "github_owner_id must be a numeric GitHub owner id."
  }
}

variable "github_subject_prefix" {
  type        = string
  description = "The repository's OIDC subject prefix when it is not repo:<org>/<repo> (gh api repos/<org>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix). Repositories created after 2026-07-15 use repo:<org>@<id>/<repo>@<id>."
  default     = null

  validation {
    condition     = var.github_subject_prefix == null || can(regex("^repo:[A-Za-z0-9][A-Za-z0-9-]*(@[0-9]+)?/[A-Za-z0-9._-]+(@[0-9]+)?$", coalesce(var.github_subject_prefix, "-")))
    error_message = "github_subject_prefix must be an exact prefix such as repo:<org>/<repo>, with no wildcard."
  }
}

variable "existing_oidc_provider_arn" {
  type        = string
  description = "ARN of the account's GitHub OIDC provider when it already has one (an account holds only one). Null creates it."
  default     = null

  validation {
    condition     = var.existing_oidc_provider_arn == null || can(regex("^arn:aws[a-z-]*:iam::${var.account_id}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", coalesce(var.existing_oidc_provider_arn, "-")))
    error_message = "existing_oidc_provider_arn must be this account's provider, arn:<partition>:iam::<account_id>:oidc-provider/token.actions.githubusercontent.com."
  }
}

variable "environments" {
  type        = list(string)
  description = "The environments deployed into this account. Each gets an apply role that trusts only its GitHub Environment."
  default     = ["dev", "production"]

  validation {
    condition     = length(var.environments) > 0 && alltrue([for e in var.environments : can(regex("^[a-z][a-z0-9]{1,11}$", e))])
    error_message = "environments must be a non-empty list of names of 2 to 12 lower-case letters or digits, starting with a letter."
  }
}

variable "production_environments" {
  type        = list(string)
  description = "The entries of environments that are production. Every other environment is denied their resources, their state and the saved plans. Must name at least one."
  default     = ["production"]

  validation {
    condition     = length(var.production_environments) > 0 && alltrue([for p in var.production_environments : contains(var.environments, p)])
    error_message = "production_environments must name at least one environment, and only names from environments: in one account, nothing else keeps dev away from production."
  }
}

variable "name_prefix" {
  type        = string
  description = "Prefix of the delivery role names (<prefix>-plan-pr, <prefix>-plan-default, <prefix>-apply-<environment>). Any value other than gha is also put in front of the boundary, budget and state bucket names, so a second baseline in one account never collides with the first."
  default     = "gha"
}

variable "service" {
  type        = string
  description = "Name base of the account-level resources, <service>-<environment>-workload-boundary and <service>-shared-monthly-cost."
  default     = "platform"
}

variable "security_name_prefix" {
  type        = string
  description = "Prefix of the security baseline's own resources (trail, buckets, alerts topic). The delivery roles are denied changes to everything it names."
  default     = "security-baseline-shared"
}

variable "access_analyzer_enabled" {
  type        = bool
  description = "Create the account's IAM Access Analyzer. An account may hold only one per Region: set false when it already has one."
  default     = true
}

variable "state_bucket_name" {
  type        = string
  description = "Name of the state bucket. Null uses <account_id>-tfstate-<region> (with the name_prefix in front of tfstate when it is not gha)."
  default     = null
}

variable "create_state_kms_key" {
  type        = bool
  description = "true encrypts state and saved plans with a customer-managed key (about 1 USD a month). false (the default) uses the bucket's AES-256 default: still encrypted at rest and reachable only over TLS."
  default     = false
}

variable "enable_api_gateway_account" {
  type        = bool
  description = "Set the account's API Gateway logging role in this Region. Set false when another stack in this account and Region already manages it."
  default     = true
}

variable "change_id" {
  type        = string
  description = "Four-digit change record number for the change tag, or null for none."
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Extra tags for resources that take tags. Keys are lower-case kebab-case."
  default     = {}
}

variable "security_kms_key_enabled" {
  type        = bool
  description = "Create the security baseline's customer-managed key. It costs $1.00 per key version per month plus requests. False encrypts the trail bucket with S3-managed keys and creates no key."
  default     = true
}

variable "access_log_bucket_enabled" {
  type        = bool
  description = "Create the second bucket that receives the trail bucket's S3 server access logs. It costs S3 storage and requests for as long as the logs are kept."
  default     = true
}

variable "log_retention_days" {
  type        = number
  description = "Days the trail keeps its log files and log events: 90, 400 or longer. The log group costs $0.50 per GB ingested in ap-southeast-6, and storage grows with the days kept."
  default     = 400
}
