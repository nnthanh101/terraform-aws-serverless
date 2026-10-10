# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.

variable "github_org" {
  description = "GitHub organisation name (e.g. 'nnthanh101' or 'example-org'). Used in the IAM trust-policy sub claim."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", var.github_org))
    error_message = "github_org must be the organisation name only (1 to 39 letters, digits or hyphens, no leading or trailing hyphen), not a URL."
  }
}

variable "github_repositories" {
  description = "List of repository names (without org prefix) that are granted trust. Each entry becomes sub claim 'repo:<org>/<repo>:*' for the plan role and 'repo:<org>/<repo>:ref:refs/heads/main' for the apply role."
  type        = list(string)

  validation {
    condition     = length(var.github_repositories) > 0 && alltrue([for r in var.github_repositories : can(regex("^[A-Za-z0-9._-]{1,100}$", r)) && !contains([".", ".."], r)])
    error_message = "github_repositories must list at least one repository name (letters, digits, dot, hyphen or underscore), without the organisation prefix and without a wildcard."
  }
}

variable "create_oidc_provider" {
  description = "Whether to create the aws_iam_openid_connect_provider for token.actions.githubusercontent.com. Set to false when one already exists in the account (one-per-account constraint)."
  type        = bool
  default     = true
}

variable "create_roles" {
  description = "Whether to create the plan and apply roles. Set to false to create only the OIDC provider (the account's one provider, for a root that has its own pipeline roles). Default true: callers that leave it out see no change."
  type        = bool
  default     = true
}

variable "plan_role_name" {
  description = "Name of the IAM role assumed by plan/readonly jobs."
  type        = string
  default     = "github-actions-plan"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.plan_role_name))
    error_message = "plan_role_name must be 1 to 64 characters of letters, digits and + = , . @ _ - (the IAM role name rule)."
  }
}

variable "apply_role_name" {
  description = "Name of the IAM role assumed by apply jobs (main-branch-only trust)."
  type        = string
  default     = "github-actions-apply"

  validation {
    condition     = can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", var.apply_role_name))
    error_message = "apply_role_name must be 1 to 64 characters of letters, digits and + = , . @ _ - (the IAM role name rule)."
  }
}

variable "plan_policy_arns" {
  description = "List of managed policy ARNs to attach to the plan/readonly role. Defaults to ReadOnlyAccess — least-privilege for plan jobs."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/ReadOnlyAccess"]

  validation {
    condition     = alltrue([for a in var.plan_policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+$", a))])
    error_message = "Every entry of plan_policy_arns must be an IAM managed policy ARN, for example arn:aws:iam::aws:policy/ReadOnlyAccess."
  }
}

variable "apply_allowed_refs" {
  description = "GitHub sub-claim ref suffixes trusted by the apply role. Defaults to main-branch push. GitHub environment: claims (e.g. 'environment:production') are valid values and preferred for protected deployments that require environment-protection reviewers — they provide an additional human-approval gate beyond branch protection."
  type        = list(string)
  default     = ["ref:refs/heads/main"]

  validation {
    condition     = length(var.apply_allowed_refs) > 0
    error_message = "apply_allowed_refs must contain at least one ref or environment claim."
  }

  validation {
    condition     = alltrue([for r in var.apply_allowed_refs : can(regex("^(ref|environment):[^\\s]+$", r))])
    error_message = "Each apply_allowed_refs entry must start with ref: or environment: and hold no spaces, for example ref:refs/heads/main or environment:production."
  }
}

variable "apply_policy_arns" {
  description = "List of managed policy ARNs to attach to the apply role. REQUIRED when create_roles is true (caller must supply explicit least-privilege policy ARNs; AdministratorAccess is never assumed); ignored when create_roles is false."
  type        = list(string)
  default     = []

  validation {
    condition     = !var.create_roles || length(var.apply_policy_arns) > 0
    error_message = "apply_policy_arns must contain at least one policy ARN. No default admin policy is set — supply the minimum required permissions for your apply workflow."
  }

  validation {
    condition     = alltrue([for a in var.apply_policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+$", a))])
    error_message = "Every entry of apply_policy_arns must be an IAM managed policy ARN, for example arn:aws:iam::aws:policy/ReadOnlyAccess."
  }
}

variable "max_session_duration" {
  description = "Maximum session duration in seconds for both roles."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 3600 && var.max_session_duration <= 43200
    error_message = "max_session_duration must be between 3600 (1h) and 43200 (12h)."
  }
}

variable "tags" {
  description = "A mapping of tags to assign to all resources. Keys are lower-case kebab-case."
  type        = map(string)
  default     = {}

  validation {
    condition     = alltrue([for k in keys(var.tags) : can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", k))])
    error_message = "Each tag key must be lower-case kebab-case, for example cost-centre or managed-by."
  }
}
