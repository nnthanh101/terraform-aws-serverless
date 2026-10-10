# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.

variable "account_id" {
  type        = string
  description = "AWS account for this environment. It makes the bucket names unique and builds the key policy and the parameter ARN; the calling root's provider sets allowed_account_ids to it."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "region" {
  type        = string
  description = "AWS Region for this environment. There is no default. It builds the parameter ARN and the S3 endpoint the files key may be used through."

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an AWS Region code."
  }
}

variable "environment" {
  type        = string
  description = "Environment name. It is part of every resource name."

  validation {
    condition     = can(regex("^[a-z][a-z0-9]{1,11}$", var.environment))
    error_message = "environment must be 2 to 12 lower-case letters or digits, starting with a letter."
  }
}

variable "service" {
  type        = string
  description = "Service name: the first part of every resource name ('<service>-<environment>-<purpose>')."

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,18}[a-z0-9]$", var.service))
    error_message = "service must be 2 to 20 lower-case letters, digits or hyphens, starting with a letter."
  }
}

variable "permissions_boundary_arn" {
  type        = string
  description = "This environment's entry in the workload_boundary_policy_arns output of the bootstrap module. The apply role creates only roles that carry its own environment's boundary."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:policy/", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be an IAM policy ARN."
  }

  validation {
    condition     = endswith(var.permissions_boundary_arn, "-${var.environment}-workload-boundary")
    error_message = "permissions_boundary_arn must be this environment's boundary, <service>-<environment>-workload-boundary. The apply role creates roles only with its own environment's boundary."
  }
}

variable "workload_role_path" {
  type        = string
  description = "IAM path segment for workload roles; roles sit under /<path>/<environment>/, as the bootstrap module expects."
  default     = "workload"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]*$", var.workload_role_path))
    error_message = "workload_role_path must be one lower-case path segment."
  }
}

variable "architecture" {
  type        = string
  description = "Lambda instruction set. arm64 costs about 20% less per GB-second; x86_64 needs architecture_exception."
  default     = "arm64"
  nullable    = false

  validation {
    condition     = contains(["arm64", "x86_64"], var.architecture)
    error_message = "architecture must be arm64 or x86_64."
  }

  validation {
    condition     = var.architecture == "arm64" || trimspace(var.architecture_exception == null ? "" : var.architecture_exception) != ""
    error_message = "x86_64 needs architecture_exception: the reason (for example a dependency with no arm64 build), recorded in the spec."
  }
}

variable "architecture_exception" {
  type        = string
  description = "Why this function runs on x86_64 instead of arm64: the reason, or the spec's exception id. Null for arm64."
  default     = null
}

variable "runtime" {
  type        = string
  description = "Lambda runtime. tflint rejects deprecated runtimes; these three are current."
  default     = "python3.13"

  validation {
    condition     = contains(["python3.13", "python3.14", "nodejs24.x"], var.runtime)
    error_message = "runtime must be python3.13, python3.14 or nodejs24.x."
  }
}

variable "handler" {
  type        = string
  description = "Handler entry point, for example handler.handler for Python or index.handler for Node.js."
  default     = "handler.handler"
}

variable "memory_mb" {
  type        = number
  description = "Lambda memory in MB. CPU scales with memory; duration cost is memory x time."
  default     = 512

  validation {
    condition     = var.memory_mb >= 128 && var.memory_mb <= 10240
    error_message = "memory_mb must be between 128 and 10240."
  }
}

variable "timeout_seconds" {
  type        = number
  description = "Lambda timeout in seconds."
  default     = 15

  validation {
    condition     = var.timeout_seconds >= 1 && var.timeout_seconds <= 30
    error_message = "timeout_seconds must be between 1 and 30 for this mode."
  }
}

variable "log_retention_days" {
  type        = number
  description = "Days to keep CloudWatch logs. Storage is billed per GB-month, so longer retention costs more."
  default     = 30
  nullable    = false

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a retention period that CloudWatch Logs supports."
  }
}

variable "throttle_rate_limit" {
  type        = number
  description = "Steady-state requests per second for the whole API, before API Gateway returns 429."
  default     = 50
  nullable    = false
}

variable "throttle_burst_limit" {
  type        = number
  description = "Short burst of requests the API accepts above the steady rate."
  default     = 100
  nullable    = false
}

variable "jwt_issuer" {
  type        = string
  description = "Optional JWT issuer URL (for example an Amazon Cognito user pool or another OIDC provider). Null leaves the API open."
  default     = null

  validation {
    condition     = var.jwt_issuer == null || startswith(coalesce(var.jwt_issuer, "-"), "https://")
    error_message = "jwt_issuer must be an https:// URL."
  }
}

variable "jwt_audience" {
  type        = list(string)
  description = "Accepted JWT audiences (client IDs). Required when jwt_issuer is set."
  default     = []

  validation {
    condition     = var.jwt_issuer == null || length(var.jwt_audience) > 0
    error_message = "jwt_audience needs at least one client ID when jwt_issuer is set."
  }
}

variable "secret_store" {
  type        = string
  description = "Where the token signing key lives. secrets-manager (the default) creates and writes the secret in this module. parameter-store reads the SecureString that the owner applies in a separate root: this module creates no secret and only grants read on its name."
  default     = "secrets-manager"
  nullable    = false

  validation {
    condition     = contains(["secrets-manager", "parameter-store"], var.secret_store)
    error_message = "secret_store must be secrets-manager or parameter-store."
  }
}

variable "source_dir" {
  type        = string
  description = "Folder with the built handler, zipped by this module. The calling root passes a path that resolves from where terraform runs. Set this or package_zip_path, not both."
  default     = null

  validation {
    condition     = (var.source_dir != null) != (var.package_zip_path != null)
    error_message = "Set exactly one of source_dir (a folder to zip) and package_zip_path (a zip already built)."
  }
}

variable "package_zip_path" {
  type        = string
  description = "A zip that is already built; it is deployed as it is and nothing is archived. Set this or source_dir, not both."
  default     = null
}

variable "build_dir" {
  type        = string
  description = "Folder where the zip of source_dir is written. Null writes <root module folder>/.build. Ignored with package_zip_path. The calling root passes a path that resolves from where terraform runs."
  default     = null
}

variable "reserved_concurrency" {
  type        = number
  description = "Concurrent executions reserved for the function. Small, so one function cannot take the account's pool; a stale write is refused by the app's conditional put, not by this number."
  default     = 4

  validation {
    condition     = var.reserved_concurrency >= 1 && var.reserved_concurrency <= 100
    error_message = "reserved_concurrency must be between 1 and 100."
  }
}

variable "environment_variables" {
  type        = map(string)
  description = "The app's own environment variables. SERVICE, ENVIRONMENT, S3DB_BUCKET, CORS_ORIGIN and the signing key's name are set by this module and win over a key of the same name."
  default     = {}
}

variable "site_source_dir" {
  type        = string
  description = "Folder with the site's front-end files. Its digest is an input, so a site-only change is a plan with changes. The calling root passes a path that resolves from where terraform runs."
}

variable "site_excluded_files" {
  type        = list(string)
  description = "Files in site_source_dir that the pipeline does not upload (container and local preview files)."
  default     = ["_nocache_server.py", "Dockerfile", "nginx.conf", ".dockerignore"]
}

variable "site_price_class" {
  type        = string
  description = "CloudFront edge locations for the site. PriceClass_100 (North America and Europe) is the cheapest."
  default     = "PriceClass_100"

  validation {
    condition     = contains(["PriceClass_100", "PriceClass_200", "PriceClass_All"], var.site_price_class)
    error_message = "site_price_class must be PriceClass_100, PriceClass_200 or PriceClass_All."
  }
}

variable "site_waf_enabled" {
  type        = bool
  description = "Attach an AWS WAF web ACL with the AWS common rule set and a per-IP rate limit. Adds a fixed monthly charge."
  default     = false
  nullable    = false
}

variable "site_rate_limit" {
  type        = number
  description = "Requests per client IP in any 5-minute window before AWS WAF blocks it."
  default     = 2000
}

variable "site_content_security_policy" {
  type        = string
  description = "Content-Security-Policy header that CloudFront adds to every response."
  default     = "default-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'self'"
  nullable    = false
}

variable "alarm_topic_arn" {
  type        = string
  description = "SNS topic that receives alarm and recovery notifications."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:sns:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", var.alarm_topic_arn))
    error_message = "alarm_topic_arn must be an SNS topic ARN."
  }
}

variable "alarm_latency_p95_ms" {
  type        = number
  description = "API p95 latency, in milliseconds, that raises the latency alarm."
  default     = 1000
}
