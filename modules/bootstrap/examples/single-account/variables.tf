# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Values come from terraform.tfvars (see terraform.tfvars.example). The module validates each one.

variable "account_id" {
  type        = string
  description = "12-digit AWS account that holds dev and production."
}

variable "region" {
  type        = string
  description = "AWS Region for the state bucket, key and roles. There is no default."
}

variable "github_repositories" {
  type        = list(string)
  description = "Repositories the GitHub roles trust, as <organisation>/<repository>."
}

variable "default_branch" {
  type        = string
  description = "The repositories' default branch, read from the repository settings."
}

variable "budget_limit_usd" {
  type        = number
  description = "Monthly cost budget for this account in US dollars."
}

variable "notification_email" {
  type        = string
  description = "Budget owner who receives the budget notifications."
}

variable "change_id" {
  type        = string
  description = "Four-digit change record number for the change tag, or null for none."
  default     = null
}

variable "tags" {
  type        = map(string)
  description = "Organisation tags for every resource, for example module.tags.common_tags."
  default     = {}
}
