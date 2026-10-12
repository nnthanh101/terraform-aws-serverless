# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# The account's default VPCs, set by default_vpcs: keep (default), adopt or remove.
# AWS creates one default VPC in every Region of a new account, with one default subnet per Availability Zone and an
# internet gateway. AWS refuses DeleteVpc while the subnets and the gateway exist, and the provider's force_destroy on
# aws_default_vpc deletes only the VPC. All three are adopted, and removal destroys them in order: internet gateway,
# subnets, then the VPC. Terraform deletes only what its state holds, so removal takes two applies:
#   keep    no default VPC resource; Terraform never touches them. Not valid once any was adopted: with the resources in
#           state, "keep" would plan their destruction, so the caller's wrapper must refuse it.
#   adopt   a plan shows, per allowed Region, the VPC, each default subnet and the attached internet gateway (an
#           import, kept by the caller) and nothing deleted; apply records them with force_destroy = true.
#   remove  no resource is declared, so the plan shows each adopted internet gateway, default subnet and aws_default_vpc
#           destroyed, which is the deletion. The caller allows only those destroys, and only with remove.
# One provider serves every Region: AWS provider 6 takes a per-resource region. The data sources are a guard: with adopt
# and no default VPC left, creating the resource would make AWS build a new default VPC, so the plan stops. Subnets and
# the gateway are looked up from the VPC that exists, so nothing is created that is not already there.
data "aws_vpc" "default" {
  for_each = var.default_vpcs == "adopt" ? toset(var.allowed_regions) : toset([])
  region   = each.key
  default  = true
}

data "aws_subnets" "default" {
  for_each = data.aws_vpc.default
  region   = each.key

  filter {
    name   = "vpc-id"
    values = [each.value.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

locals {
  # "<region>/<subnet id>" for each default subnet that exists; the keys are known at plan.
  default_subnets = merge([for r, d in data.aws_subnets.default : { for id in d.ids : "${r}/${id}" => { region = r, id = id } }]...)
}

data "aws_subnet" "default" {
  for_each = local.default_subnets
  region   = each.value.region
  id       = each.value.id
}

data "aws_internet_gateway" "default" {
  for_each = data.aws_vpc.default
  region   = each.key

  filter {
    name   = "attachment.vpc-id"
    values = [each.value.id]
  }
}

resource "aws_default_vpc" "this" {
  # checkov:skip=CKV_AWS_148:0067 the default VPC is adopted only so that default_vpcs = remove can delete it in a reviewed plan
  for_each = data.aws_vpc.default
  region   = each.key

  # Deleted when the setting moves to remove. Never the management account: the variable's validation.
  force_destroy = true
  tags          = { Name = "default-vpc-${each.key}" }
}

resource "aws_default_subnet" "this" {
  for_each          = local.default_subnets
  region            = each.value.region
  availability_zone = data.aws_subnet.default[each.key].availability_zone

  # AWS refuses DeleteVpc while a subnet exists: destroyed before the VPC (depends_on is kept in state, so the order holds under remove).
  force_destroy = true
  depends_on    = [aws_default_vpc.this]
}

# The default VPC's internet gateway already exists, so the caller imports it. Terraform allows an import block only in
# the root module, so it cannot live here: the calling root keeps
#   import {
#     for_each = module.<name>.default_igw_ids
#     to       = module.<name>.aws_internet_gateway.this[each.key]
#     id       = "${each.value}@${each.key}"
#   }
# ("@<region>" names the Region: provider 6 import ID). Once recorded, the block is a no-op. The gateway is destroyed
# (detached, then deleted) before the subnets' VPC.
resource "aws_internet_gateway" "this" {
  for_each = data.aws_internet_gateway.default
  region   = each.key
  vpc_id   = data.aws_vpc.default[each.key].id # the id the plan knows; depends_on below orders the destroy
  tags     = { Name = "default-igw-${each.key}" }

  depends_on = [aws_default_vpc.this, aws_default_subnet.this]
}

# Beyond the variable's check against management_account_id (which the caller types), read the organization itself: a
# member account may call organizations:DescribeOrganization, so the plan stops when the signed-in account is the
# management account whatever the caller passed. Only read when default VPCs are touched.
data "aws_organizations_organization" "this" {
  count = var.default_vpcs == "keep" ? 0 : 1
}

# The guard is a resource so that it holds under remove too, where no default VPC resource is declared.
resource "terraform_data" "management_account_guard" {
  count = var.default_vpcs == "keep" ? 0 : 1

  lifecycle {
    precondition {
      condition     = data.aws_organizations_organization.this[0].master_account_id != var.account_id
      error_message = "default_vpcs adopt or remove is refused in the management account: ${var.account_id} is the organization's management account."
    }
  }
}
