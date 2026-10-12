# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# A LOCAL Resource Explorer index in each allowed Region of this member account. Off by default.
# The organization's aggregator in the management account gathers these.
resource "aws_resourceexplorer2_index" "local" {
  for_each = var.resource_explorer ? toset(var.allowed_regions) : toset([])
  region   = each.key
  type     = "LOCAL"
}
