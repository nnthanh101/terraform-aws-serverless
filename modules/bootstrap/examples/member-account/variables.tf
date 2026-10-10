# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# The module validates every value; the descriptions say where each one is read from.
variable "account_id" {
  description = "The member account, as the organization lists it."
  type        = string
}

variable "region" {
  description = "The landing zone's Region (AWS_SSO_REGION in the tenant settings). There is no default."
  type        = string
}

variable "github_repositories" {
  description = "<organisation>/<repository> of each repository whose pipelines deploy into this account."
  type        = list(string)
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
}

variable "notification_email" {
  description = "The watched mailbox for budget alerts (LZ_BUDGET_ALERT_EMAIL in .env, never tracked)."
  type        = string
}

variable "change_id" {
  description = "The four-digit change record this apply belongs to, written to the change tag."
  type        = string
  default     = null
}

variable "service" {
  description = "Short name that starts resource names and fills the service tag."
  type        = string
  default     = "platform"
}

variable "account_mode" {
  description = "single: one account holds every environment; landing-zone: one account per environment."
  type        = string
}

variable "environments" {
  description = "The environments this account holds; each gets an apply role that trusts only its GitHub Environment."
  type        = list(string)
}

variable "production_environments" {
  description = "The entries of environments that are production; [] for an account that holds none."
  type        = list(string)
}

variable "tags" {
  description = "Cost tags on every resource, for example service, environment and change."
  type        = map(string)
  default     = {}
}
