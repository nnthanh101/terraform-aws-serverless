# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
variable "account_id" {
  description = "The tenant's management account (the tenant settings' AWS_ROOT_ACCOUNT_ID)."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit string."
  }
}

variable "region" {
  description = "The landing zone's Region (AWS_SSO_REGION in the tenant settings). There is no default."
  type        = string
}

variable "github_repository" {
  description = "<organisation>/<repository> of the landing zone's code. With no pipeline role here, it only names the source."
  type        = string
}

variable "default_branch" {
  description = "The repository's default branch."
  type        = string
}

variable "state_bucket_name" {
  description = "The state bucket: <service>-shared-tfstate-<account id>."
  type        = string
}

variable "budget_limit_usd" {
  description = "Monthly budget in US dollars, set by the budget owner. Alerts at 80% and 100%; credits are left out."
  type        = number
}

variable "notification_email" {
  description = "The watched mailbox for budget alerts (LZ_BUDGET_ALERT_EMAIL in .env, never tracked)."
  type        = string
}

variable "change_id" {
  description = "The change record this apply belongs to, four digits."
  type        = string
}

variable "service" {
  description = "First part of resource names and the service tag."
  type        = string
  default     = "platform"
}

variable "alternate_contacts" {
  description = "The account's alternate contacts, keyed by billing, operations or security."
  type = map(object({
    name  = string
    title = string
    email = string
    phone = string
  }))
  default = {}
}
