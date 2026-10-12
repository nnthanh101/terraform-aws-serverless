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

variable "ci_platform" {
  description = "The pipeline platform the roles trust: github (GitHub Actions, the default) or azure-devops (Azure DevOps service connections). Everything else the module builds is the same for both."
  type        = string
  default     = "github"

  validation {
    condition     = contains(["github", "azure-devops"], var.ci_platform)
    error_message = "ci_platform must be github or azure-devops."
  }
}

variable "github_repositories" {
  description = "Repositories the GitHub roles trust, each as <organisation>/<repository>. Every role trusts the exact subject of each one. Required with ci_platform = github; not used with azure-devops."
  type        = list(string)
  default     = []

  validation {
    condition     = var.ci_platform != "github" || (length(var.github_repositories) > 0 && alltrue([for r in var.github_repositories : can(regex("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$", r))]))
    error_message = "github_repositories must list at least one <organisation>/<repository>, with no wildcard."
  }

  validation {
    condition     = length(distinct(var.github_repositories)) == length(var.github_repositories)
    error_message = "github_repositories must not list a repository twice."
  }

  validation {
    condition     = var.ci_platform != "azure-devops" || length(var.github_repositories) == 0
    error_message = "github_repositories is a GitHub input; leave it empty with ci_platform = azure-devops."
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

  validation {
    condition     = var.ci_platform != "azure-devops" || length(var.github_repository_ids) == 0
    error_message = "github_repository_ids is a GitHub input; leave it empty with ci_platform = azure-devops."
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

  validation {
    condition     = var.ci_platform != "azure-devops" || length(var.github_subject_prefixes) == 0
    error_message = "github_subject_prefixes is a GitHub input; leave it empty with ci_platform = azure-devops."
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

  validation {
    condition     = var.ci_platform != "azure-devops" || var.github_owner_id == null
    error_message = "github_owner_id is a GitHub input; leave it empty with ci_platform = azure-devops."
  }
}

variable "github_owner_ids" {
  description = "Numeric GitHub owner IDs of github_repositories, in the same order, for repositories held by more than one organisation. When set, the repository_owner_id claim lists the distinct IDs. Do not set together with github_owner_id."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for i in var.github_owner_ids : can(regex("^[0-9]+$", i))])
    error_message = "Each github_owner_ids entry must be a numeric GitHub owner ID."
  }

  validation {
    condition     = length(var.github_owner_ids) == 0 || length(var.github_owner_ids) == length(var.github_repositories)
    error_message = "github_owner_ids must be empty or give one ID for each entry of github_repositories."
  }

  validation {
    condition     = length(var.github_owner_ids) == 0 || var.github_owner_id == null
    error_message = "Set github_owner_id or github_owner_ids, not both."
  }

  validation {
    condition     = var.ci_platform != "azure-devops" || length(var.github_owner_ids) == 0
    error_message = "github_owner_ids is a GitHub input; leave it empty with ci_platform = azure-devops."
  }
}

# ------------------------------------------------------------------ Azure DevOps (ci_platform = "azure-devops")

variable "ado_organization_id" {
  description = "Azure DevOps organization GUID (lower-case); part of the token issuer https://vstoken.dev.azure.com/<GUID>. Required with ci_platform = azure-devops and ci_roles = true; refused with github."
  type        = string
  default     = null

  validation {
    condition     = var.ci_platform == "github" ? var.ado_organization_id == null : (!var.ci_roles || can(regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", coalesce(var.ado_organization_id, "-"))))
    error_message = "ado_organization_id must be a lower-case GUID such as 11111111-1111-1111-1111-111111111111 with ci_platform = azure-devops, and must stay null with github."
  }
}

variable "ado_organization_name" {
  description = "Azure DevOps organization name, the first segment of the subject sc://<organization>/<project>/<connection>. No wildcard characters. Required with ci_platform = azure-devops and ci_roles = true; refused with github."
  type        = string
  default     = null

  validation {
    condition     = var.ci_platform == "github" ? var.ado_organization_name == null : (!var.ci_roles || (length(trimspace(coalesce(var.ado_organization_name, ""))) > 0 && !can(regex("[*?$/]", coalesce(var.ado_organization_name, "")))))
    error_message = "ado_organization_name must be set, without * ? $ or /, with ci_platform = azure-devops, and must stay null with github."
  }
}

variable "ado_plan_service_connections" {
  description = "Service connections the two plan roles trust, each { project, name }. Exact names only; at least one with ci_platform = azure-devops and ci_roles = true; refused with github."
  type = list(object({
    project = string
    name    = string
  }))
  default = []

  validation {
    condition     = var.ci_platform == "azure-devops" || length(var.ado_plan_service_connections) == 0
    error_message = "ado_plan_service_connections is for ci_platform = azure-devops; leave it empty with github."
  }

  validation {
    condition     = var.ci_platform != "azure-devops" || !var.ci_roles || length(var.ado_plan_service_connections) > 0
    error_message = "ado_plan_service_connections needs at least one service connection with ci_platform = azure-devops."
  }

  validation {
    condition     = alltrue([for c in var.ado_plan_service_connections : length(trimspace(c.project)) > 0 && length(trimspace(c.name)) > 0])
    error_message = "Every plan service connection needs a non-empty project and name."
  }

  validation {
    condition     = alltrue([for c in var.ado_plan_service_connections : !can(regex("[*?$/]", c.project)) && !can(regex("[*?$/]", c.name))])
    error_message = "Plan service connection project and name must not contain * ? $ or /, so a subject can never be a pattern."
  }
}

variable "ado_apply_service_connections" {
  description = "Per environment, the service connections its apply role trusts, each { project, name }. Every entry of environments needs at least one with ci_platform = azure-devops and ci_roles = true; keys must be entries of environments; refused with github."
  type = map(list(object({
    project = string
    name    = string
  })))
  default = {}

  validation {
    condition     = var.ci_platform == "azure-devops" || length(var.ado_apply_service_connections) == 0
    error_message = "ado_apply_service_connections is for ci_platform = azure-devops; leave it empty with github."
  }

  validation {
    condition     = alltrue([for e in keys(var.ado_apply_service_connections) : contains(var.environments, e)])
    error_message = "ado_apply_service_connections may name only entries of environments."
  }

  validation {
    condition     = var.ci_platform != "azure-devops" || !var.ci_roles || alltrue([for e in var.environments : length(lookup(var.ado_apply_service_connections, e, [])) > 0])
    error_message = "With ci_platform = azure-devops every entry of environments needs at least one apply service connection."
  }

  # A connection is trusted by one role set only: ADO names are case-insensitive, so compare lower-cased.
  validation {
    condition = (
      length(concat(distinct([for c in var.ado_plan_service_connections : lower("${c.project}/${c.name}")]), flatten([for e, cs in var.ado_apply_service_connections : distinct([for c in cs : lower("${c.project}/${c.name}")])])))
      == length(distinct(concat([for c in var.ado_plan_service_connections : lower("${c.project}/${c.name}")], flatten([for e, cs in var.ado_apply_service_connections : distinct([for c in cs : lower("${c.project}/${c.name}")])]))))
    )
    error_message = "A service connection may be trusted by only one of the plan roles and each apply environment: ado_apply_service_connections must be disjoint from ado_plan_service_connections and between environments (names compared case-insensitively)."
  }

  validation {
    condition     = alltrue([for e, cs in var.ado_apply_service_connections : alltrue([for c in cs : length(trimspace(c.project)) > 0 && length(trimspace(c.name)) > 0 && !can(regex("[*?$/]", c.project)) && !can(regex("[*?$/]", c.name))])])
    error_message = "Every apply service connection needs a non-empty project and name without * ? $ or /, so a subject can never be a pattern."
  }
}

variable "workload_boundary_extra_actions" {
  description = "Per environment, extra read actions (no wildcard; no iam, sts or organizations) added to that environment's workload boundary."
  type        = map(list(string))
  default     = {}

  validation {
    condition     = alltrue([for e in keys(var.workload_boundary_extra_actions) : contains(var.environments, e)])
    error_message = "workload_boundary_extra_actions keys must be entries of environments."
  }

  validation {
    condition     = alltrue([for e, l in var.workload_boundary_extra_actions : alltrue([for a in l : can(regex("^[a-z0-9-]+:(Get|Describe|List|View|Lookup|BatchGet|Search)[A-Za-z0-9]*$", a)) && !startswith(a, "iam:") && !startswith(a, "sts:") && !startswith(a, "organizations:")])])
    error_message = "Each workload_boundary_extra_actions entry must be an enumerated read action such as bedrock:GetAgent: no wildcard, and no iam, sts or organizations action."
  }

  validation {
    condition     = alltrue([for e, l in var.workload_boundary_extra_actions : alltrue([for a in l : !can(regex("(?i)(Credentials|Token|PasswordData|SecretValue|AccessDetails)", a))])])
    error_message = "workload_boundary_extra_actions must not list an action that returns credentials, such as redshift:GetClusterCredentials, ecr:GetAuthorizationToken or ec2:GetPasswordData."
  }
}

variable "passrole_services" {
  description = "Extra service principals (for example bedrock-agentcore.amazonaws.com) the apply roles may pass workload roles to, besides Lambda and Step Functions."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.passrole_services : can(regex("^[a-z0-9-]+(\\.[a-z0-9-]+)*\\.amazonaws\\.com$", s))])
    error_message = "Each passrole_services entry must be a service principal ending in .amazonaws.com."
  }

  validation {
    condition     = length(setintersection(var.passrole_services, ["cloudformation.amazonaws.com", "codebuild.amazonaws.com", "ec2.amazonaws.com"])) == 0
    error_message = "passrole_services must not list cloudformation, codebuild or ec2: they run arbitrary code with the passed role."
  }
}

variable "container_repositories" {
  description = "Names of container image registries (ECR) for apps shipped as Lambda container images: immutable tags, scan on push, AES256, untagged images expire beyond the newest 20, Lambda in this account may pull. Empty creates none."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for n in var.container_repositories : can(regex("^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$", n)) && length(n) >= 2 && length(n) <= 256])
    error_message = "Each container_repositories name must be a valid ECR name: lower-case letters, digits and . _ - separators (and / for a path), 2 to 256 characters."
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

  validation {
    condition     = var.ci_platform != "azure-devops" || length(var.apply_workflow_refs) == 0
    error_message = "apply_workflow_refs is a GitHub input; leave it empty with ci_platform = azure-devops."
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
  description = "Create the OIDC trust (GitHub or Azure DevOps, per ci_platform) and the plan and apply roles. Turn it off in an organization's management account: a person applies the landing zone there, so the account needs its state bucket, key and budget only."
  type        = bool
  default     = true
}

variable "create_oidc_provider" {
  description = "Create the account's OIDC provider for the ci_platform issuer (GitHub or Azure DevOps). An account holds only one; a second tenant in the same account sets false and passes oidc_provider_arn. Ignored with ci_roles = false."
  type        = bool
  default     = true
}

variable "oidc_provider_arn" {
  description = "ARN of the account's existing OIDC provider for the ci_platform issuer. Required when create_oidc_provider = false, and refused otherwise. Ignored with ci_roles = false."
  type        = string
  default     = null

  validation {
    # With ci_roles = false the module trusts no provider, so none is required.
    condition = !var.ci_roles || (
      var.create_oidc_provider ? var.oidc_provider_arn == null :
      can(regex(var.ci_platform == "azure-devops" ? "^arn:aws[a-z-]*:iam::${var.account_id}:oidc-provider/vstoken\\.dev\\.azure\\.com/${coalesce(var.ado_organization_id, "none")}$" : "^arn:aws[a-z-]*:iam::${var.account_id}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.oidc_provider_arn))
    )
    error_message = "With create_oidc_provider = false, set oidc_provider_arn to this account's provider for the ci_platform issuer: arn:<partition>:iam::<account_id>:oidc-provider/token.actions.githubusercontent.com for github, or .../vstoken.dev.azure.com/<ado_organization_id> for azure-devops. With create_oidc_provider = true, leave it null."
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
