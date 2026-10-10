# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# The account baseline with every default kept: a multi-Region trail, its encrypted bucket, key and log group, the
# alarms and the dashboard; every control that adds a monthly charge stays off. The three inputs below are required;
# the account ID and e-mail are examples, and all tag values are placeholders. Set trail_scope = "organization" (and
# organization_service_access_principals) to record every member account, from the management account.
variable "account_id" {
  type        = string
  description = "The 12-digit account this baseline protects."
  default     = "111122223333"
}

variable "alert_email" {
  type        = string
  description = "Address that receives the alarms."
  default     = "security@example.com"
}

variable "region" {
  type        = string
  description = "Region the provider calls AWS from."
  default     = "us-east-1"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      cost-centre         = "example-cost-centre"
      project             = "example-project"
      environment         = "example"
      data-classification = "internal"
    }
  }
}

module "security_baseline" {
  source = "../.."

  account_id  = var.account_id
  region      = var.region
  alert_email = var.alert_email
}
