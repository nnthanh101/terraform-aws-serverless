# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# management-account: an organization's management account. The owner applies it once, from their own terminal and
# signed in through IAM Identity Center, never from a pipeline: state bucket, key, budget,
# with no GitHub trust and no plan or apply role. Its outputs fill the tenant's state settings and the automation
# guardrail. A tenant root calls the module the same way, by a git source pinned to a 40-hex commit.
module "bootstrap" {
  source = "../.."

  account_id          = var.account_id
  region              = var.region
  github_repositories = [var.github_repository]
  default_branch      = var.default_branch
  state_bucket_name   = var.state_bucket_name
  budget_limit_usd    = var.budget_limit_usd
  notification_email  = var.notification_email
  change_id           = var.change_id
  service             = var.service

  # A management account: a person applies the landing zone there, so no GitHub trust, pipeline role or
  # API Gateway logging role.
  ci_roles                   = false
  enable_api_gateway_account = false
  account_mode               = "landing-zone"
  environments               = ["dev"]
  production_environments    = []

  alternate_contacts = var.alternate_contacts
}
