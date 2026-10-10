# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Derived from the terraform-aws plugin's bootstrap template. See NOTICE.txt.

# Who AWS contacts about billing, operations and security, instead of the root email alone.
resource "aws_account_alternate_contact" "this" {
  for_each               = var.alternate_contacts
  alternate_contact_type = upper(each.key)
  name                   = each.value.name
  title                  = each.value.title
  email_address          = each.value.email
  phone_number           = each.value.phone
}
