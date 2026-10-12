# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Every value comes from the account's tfvars through the root that calls this module.
# Nothing here defaults to an account or a Region. Every switch that adds a monthly charge is off.

variable "account_id" {
  type        = string
  description = "The account this baseline protects. Every ARN is built from it, so policies are known at plan."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  type        = string
  description = "Home Region: the trail, log group, alarms, topic and every regional control live here. No default."

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an AWS Region code."
  }
}

variable "name_prefix" {
  type        = string
  description = "Prefix of every name this module creates, <service>-shared. At most 32 characters, so the bucket names stay within 63."
  default     = "security-baseline-shared"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name_prefix))
    error_message = "name_prefix must be 3 to 32 lower-case letters, digits or hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "trail_scope" {
  type        = string
  description = "account: the trail records this account only. organization: an organization trail that also records every member account; run it from the management account, and set organization_service_access_principals."
  default     = "account"

  validation {
    condition     = contains(["account", "organization"], var.trail_scope)
    error_message = "trail_scope must be account or organization."
  }
}

variable "organization_service_access_principals" {
  type        = list(string)
  description = "Service principals that have trusted access in the organization; pass module.organizations.service_access_principals. Read only when trail_scope is organization, which is refused unless the list holds cloudtrail.amazonaws.com."
  default     = []
}

variable "alert_email" {
  type        = string
  description = "Address that receives alarm and finding notifications. AWS sends a confirmation message first; nothing arrives until someone confirms it."

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.alert_email))
    error_message = "alert_email must be an email address."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Days the trail keeps its log files and log events. 400 covers a 12-month audit period and the fieldwork after it; 90 is for an account with no audit period."
  default     = 400

  validation {
    condition     = contains([90, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be 90 or a CloudWatch Logs retention value of at least 400: 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}

variable "s3_data_event_bucket_names" {
  type        = list(string)
  description = "Buckets whose object reads and writes the trail records as data events. Charged per event."
  default     = []

  validation {
    condition     = alltrue([for b in var.s3_data_event_bucket_names : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", b))])
    error_message = "s3_data_event_bucket_names must be S3 bucket names."
  }

  # The trail writing its own files would record its own writes, without end.
  validation {
    condition     = length(setintersection(toset(var.s3_data_event_bucket_names), toset(["${var.name_prefix}-trail-${var.account_id}", "${var.name_prefix}-access-logs-${var.account_id}"]))) == 0
    error_message = "s3_data_event_bucket_names must not name the baseline's own trail or access-log bucket."
  }
}

variable "kms_key_enabled" {
  type        = bool
  description = "One customer-managed key for the trail files, the trail log group and the alerts topic. False uses S3-managed encryption (SSE-S3) for the trail bucket, leaves the log group and the alerts topic on the service's default, and creates no key."
  default     = true
}

variable "access_log_bucket_enabled" {
  type        = bool
  description = "A second bucket that receives the trail bucket's S3 server access logs, so reads of the audit trail are themselves recorded."
  default     = true
}

variable "default_security_group_lockdown_enabled" {
  type        = bool
  description = "Remove every rule from the default VPC's default security group in the home Region, and deny adding rules in that VPC to the delivery roles."
  default     = true
}

variable "guardduty_enabled" {
  type        = bool
  description = "GuardDuty in the home Region, with S3 data events and EBS malware protection, and its high-severity findings sent to the alerts topic."
  default     = false
}

variable "config_enabled" {
  type        = bool
  description = "AWS Config recording in the home Region, daily, delivered to the trail bucket."
  default     = false
}

variable "security_hub_enabled" {
  type        = bool
  description = "Security Hub in the home Region with the AWS Foundational Security Best Practices standard, and its critical and high findings sent to the alerts topic."
  default     = false

  validation {
    condition     = !var.security_hub_enabled || var.config_enabled
    error_message = "security_hub_enabled needs config_enabled: Security Hub controls are evaluated from AWS Config recordings."
  }
}

variable "inspector_enabled" {
  type        = bool
  description = "Amazon Inspector scanning of EC2, ECR and Lambda in the home Region."
  default     = false

  # Regions where AWS does not offer Inspector, as dated. Remove a Region when AWS adds it.
  validation {
    condition     = !var.inspector_enabled || !contains(["ap-southeast-6"], var.region)
    error_message = "inspector_enabled cannot be true in this Region: Amazon Inspector is not offered in ap-southeast-6 (AWS documentation and price list, checked 2026-09-24)."
  }
}

variable "inspector_resource_types" {
  type        = list(string)
  description = "What Inspector scans when inspector_enabled is on."
  default     = ["EC2", "ECR", "LAMBDA"]

  validation {
    condition     = length(var.inspector_resource_types) > 0 && alltrue([for t in var.inspector_resource_types : contains(["EC2", "ECR", "LAMBDA", "LAMBDA_CODE", "CODE_REPOSITORY"], t)])
    error_message = "inspector_resource_types must list one or more of EC2, ECR, LAMBDA, LAMBDA_CODE and CODE_REPOSITORY."
  }
}

variable "unauthorized_api_calls_alarm_enabled" {
  type        = bool
  description = "The alarm on refused calls (CIS, 5 within 5 minutes). Its metric and dashboard widget stay when it is off."
  default     = true
}

variable "waf_enabled" {
  type        = bool
  description = "A web ACL with the AWS common, known-bad-inputs and SQL injection rule groups and a per-IP rate limit. A fixed monthly charge per web ACL and rule, plus requests."
  default     = false
}

variable "waf_scope" {
  type        = string
  description = "REGIONAL for API Gateway, load balancers and similar in the home Region; CLOUDFRONT for distributions, created in us-east-1 as AWS requires."
  default     = "REGIONAL"

  validation {
    condition     = contains(["REGIONAL", "CLOUDFRONT"], var.waf_scope)
    error_message = "waf_scope must be REGIONAL or CLOUDFRONT."
  }
}

variable "waf_rate_limit" {
  type        = number
  description = "Requests per client IP in any 5-minute window before the web ACL blocks it."
  default     = 2000

  validation {
    condition     = var.waf_rate_limit >= 10 && var.waf_rate_limit <= 2000000000 && floor(var.waf_rate_limit) == var.waf_rate_limit
    error_message = "waf_rate_limit must be a whole number from 10 to 2000000000."
  }
}

variable "waf_resource_arns" {
  type        = list(string)
  description = "Regional resources (API Gateway stages, load balancers) the web ACL protects. A CloudFront distribution names the web ACL itself, so this stays empty for CLOUDFRONT."
  default     = []

  validation {
    condition     = alltrue([for a in var.waf_resource_arns : can(regex("^arn:aws[a-z-]*:", a))])
    error_message = "waf_resource_arns must be ARNs."
  }

  validation {
    condition     = var.waf_scope == "REGIONAL" || length(var.waf_resource_arns) == 0
    error_message = "waf_resource_arns must be empty for CLOUDFRONT: the distribution names the web ACL in its own settings."
  }

  # Each one is named in SecurityBaselineProtectWebAcl; ten keeps it well inside IAM's 6,144 characters (a test checks).
  validation {
    condition     = length(var.waf_resource_arns) <= 10
    error_message = "waf_resource_arns names at most 10 resources."
  }
}

variable "break_glass_principal_arns" {
  type        = list(string)
  description = "IAM users, each signing in with MFA, who may assume BreakGlassAdmin. Empty means no break-glass role."
  default     = []

  validation {
    condition     = alltrue([for a in var.break_glass_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:user/.+$", a)) && !strcontains(a, "*")])
    error_message = "break_glass_principal_arns must be IAM user ARNs, without wildcards: only a person with an MFA device may use the break-glass role."
  }
}

variable "break_glass_external_id" {
  type        = string
  description = "External ID that BreakGlassAdmin requires, generated by the root and kept in its state. Required when break_glass_principal_arns names anyone."
  default     = null
  sensitive   = true

  validation {
    condition     = length(var.break_glass_principal_arns) == 0 || var.break_glass_external_id != null
    error_message = "break_glass_external_id is required when break_glass_principal_arns names anyone: BreakGlassAdmin trusts only callers that present it."
  }

  validation {
    condition     = var.break_glass_external_id == null || can(regex("^[A-Za-z0-9+=,.@:/_-]{16,128}$", var.break_glass_external_id))
    error_message = "break_glass_external_id must be 16 to 128 letters, digits or +=,.@:/_- characters."
  }
}

variable "trusted_principal_arns" {
  type        = list(string)
  description = "Who may assume SecurityAuditor and DeveloperTemplate: user ARNs (each then needs an MFA sign-in within the hour), role ARNs, or role patterns such as the Identity Center roles arn:aws:iam::<account>:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_<set>_*, which match with or without the Region segment in the path. Empty means neither role exists."
  default     = []

  validation {
    condition     = alltrue([for a in var.trusted_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(user|role)/.+$", a))])
    error_message = "trusted_principal_arns must be IAM user or role ARNs, or patterns of them."
  }

  # A pattern that matches every role would let the delivery roles in too.
  validation {
    condition     = alltrue([for a in var.trusted_principal_arns : !can(regex(":(user|role)/[*]+$", a))])
    error_message = "trusted_principal_arns must not be a bare wildcard such as role/*: name the people's roles or users."
  }

  # The delivery and workload roles, by the same patterns the resource policies deny (the part of each
  # before its first wildcard), plus gha-, which templates/bootstrap names whatever the workload path.
  validation {
    condition = alltrue([for a in var.trusted_principal_arns : !strcontains(a, "gha-") && alltrue([
      for p in var.pipeline_role_patterns : !strcontains(a, split("*", p)[0]) if split("*", p)[0] != ""
    ])])
    error_message = "trusted_principal_arns must not name a delivery role (gha-*) or a workload role (pipeline_role_patterns, workload/* by default)."
  }
}

variable "developer_environments" {
  type        = list(string)
  description = "Environments whose logs and functions DeveloperTemplate may read and invoke, by the <service>-<environment>- naming rule."
  default     = ["dev"]

  validation {
    condition     = alltrue([for e in var.developer_environments : can(regex("^[a-z][a-z0-9]{1,11}$", e))])
    error_message = "developer_environments must be names of 2 to 12 lower-case letters or digits, starting with a letter."
  }

  validation {
    condition     = length(setintersection(toset(var.developer_environments), toset(var.production_environments))) == 0
    error_message = "developer_environments must not name a production environment."
  }
}

variable "production_environments" {
  type        = list(string)
  description = "Values of the environment tag that DeveloperTemplate is denied, whatever its other rights say."
  default     = ["production"]

  validation {
    condition     = alltrue([for e in var.production_environments : can(regex("^[a-z][a-z0-9]{1,11}$", e))])
    error_message = "production_environments must be names of 2 to 12 lower-case letters or digits, starting with a letter."
  }
}

variable "ci_apply_role_names" {
  type        = list(string)
  description = "The account's apply roles (gha-apply-<environment>) that get SecurityBaselineProtect attached."
  default     = []

  validation {
    condition     = alltrue([for n in var.ci_apply_role_names : can(regex("^[A-Za-z0-9+=,.@_-]{1,64}$", n))])
    error_message = "ci_apply_role_names must be IAM role names."
  }
}

variable "pipeline_role_patterns" {
  type        = list(string)
  description = "Role name patterns of the delivery pipeline and the workloads it creates: gha-* and <service_role_path>/* of templates/bootstrap. The key, bucket and topic policies deny them, whatever their own policies say, and trusted_principal_arns may not name them."
  default     = ["gha-*", "workload/*"]

  validation {
    condition     = length(var.pipeline_role_patterns) > 0 && alltrue([for p in var.pipeline_role_patterns : can(regex("^[A-Za-z0-9+=,.@_*-][A-Za-z0-9+=,.@_/*-]{0,511}$", p))])
    error_message = "pipeline_role_patterns must be a non-empty list of IAM role names or path/name patterns, such as gha-* or workload/*."
  }
}

variable "protected_key_tag" {
  type = object({
    key   = string
    value = string
  })
  description = "Tag put on the baseline's KMS key so the organization's protect-security-logging guardrail covers it. The default is the organizations module's protected_tag output, lz:protected = true, the one key that is not kebab-case; set the key and value your own guardrail matches, or null to leave the key untagged."
  default     = { key = "lz:protected", value = "true" }

  validation {
    condition     = var.protected_key_tag == null ? true : (var.protected_key_tag.key == "lz:protected" || can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*$", var.protected_key_tag.key))) && length(var.protected_key_tag.value) > 0
    error_message = "protected_key_tag.key must be lower-case kebab-case, or lz:protected, and its value must not be empty."
  }
}

variable "protect_policy_prefix" {
  type        = string
  description = "Prefix of the two deny-only policy names, <prefix>Protect and <prefix>ProtectWebAcl. The default keeps SecurityBaselineProtect and SecurityBaselineProtectWebAcl; set another when the account already holds policies of those names (IAM policy names are unique per account)."
  default     = "SecurityBaseline"

  validation {
    condition     = can(regex("^[A-Za-z][A-Za-z0-9+=,.@_-]{0,40}$", var.protect_policy_prefix))
    error_message = "protect_policy_prefix must be 1 to 41 IAM-name characters, starting with a letter, so the longer name stays within IAM's 128."
  }
}

variable "access_analyzer_enabled" {
  type        = bool
  description = "Create the account's IAM Access Analyzer (type ACCOUNT). An account may hold only one per Region: set false when it already has one, and its findings still reach the alerts topic."
  default     = true
}

variable "imds_v2_required" {
  type        = bool
  description = "Require IMDSv2 tokens for new instances in the home Region (hop limit 2). Off by default; the account-wide default can be set once per Region."
  default     = false
}
