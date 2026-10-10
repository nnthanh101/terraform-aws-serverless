# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# member-account: an organization member account that runs workloads. The owner applies it once per account, from
# their own terminal, after the account exists; pipelines then sign in with short-lived GitHub OIDC tokens, never a
# stored key. Each apply role trusts only its GitHub Environment, which carries the named approver, and, where
# apply_workflow_refs lists the environment, only the release workflow. One tfvars file per account kind:
#   workload.tfvars.example   dev and production in one account: dev is denied production resources, state and plans
#   sandbox.tfvars.example    one environment and no production role; budget alerts at 80% and 100%
#   card-data.tfvars.example  a card-data workload in its own account: production only, released by one workflow
module "bootstrap" {
  source = "../.."

  account_id              = var.account_id
  region                  = var.region
  github_repositories     = var.github_repositories
  github_repository_ids   = var.github_repository_ids
  github_subject_prefixes = var.github_subject_prefixes
  github_owner_id         = var.github_owner_id
  default_branch          = var.default_branch
  apply_workflow_refs     = var.apply_workflow_refs
  budget_limit_usd        = var.budget_limit_usd
  notification_email      = var.notification_email
  change_id               = var.change_id
  service                 = var.service

  account_mode            = var.account_mode
  environments            = var.environments
  production_environments = var.production_environments

  # The same map as default_tags, so the module adds no lower-case copy of a key it already carries.
  tags = var.tags
}
