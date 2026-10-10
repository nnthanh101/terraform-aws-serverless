# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Derived from the terraform-aws plugin's bootstrap template. See NOTICE.txt.
# Break-glass for an organization's management account, for when Identity Center or the identity
# provider is down. One IAM user with administrator rights and no access key. Terraform never holds
# its password or MFA: the owner adds both in the console after the apply, and seals them with the
# root credentials. Until MFA is on, the user can do nothing but set up its own MFA and password.
# Service control policies do not apply to the management account, so the no-IAM-users guardrail on
# the units does not block this user. Off by default: a workload account has no break-glass user.

resource "aws_iam_user" "break_glass" {
  # checkov:skip=CKV_AWS_273:the root account's sign-in with MFA is the only other way in when Identity Center is down; this one user has no key and is MFA-gated
  count = var.break_glass_user ? 1 : 0
  name  = "break-glass"
  path  = var.break_glass_path
  tags  = local.tags
}


resource "aws_iam_user_policy_attachment" "break_glass_admin" {
  # checkov:skip=CKV_AWS_40:the break-glass user is a single named user by design, not a group member
  count      = var.break_glass_user ? 1 : 0
  user       = aws_iam_user.break_glass[0].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

# Everything is denied without MFA, except what the user needs to add its own MFA device and change
# its own password at first sign-in.
resource "aws_iam_user_policy" "break_glass_require_mfa" {
  # checkov:skip=CKV_AWS_40:the MFA requirement is attached to the single break-glass user it guards
  count = var.break_glass_user ? 1 : 0
  name  = "RequireMfa"
  user  = aws_iam_user.break_glass[0].name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "DenyAllWithoutMfa"
      Effect = "Deny"
      NotAction = [
        "iam:CreateVirtualMFADevice", "iam:EnableMFADevice", "iam:ListMFADevices", "iam:ListVirtualMFADevices",
        "iam:ResyncMFADevice", "iam:GetUser", "iam:ChangePassword", "iam:GetAccountPasswordPolicy",
        "sts:GetSessionToken",
      ]
      Resource  = "*"
      Condition = { BoolIfExists = { "aws:MultiFactorAuthPresent" = "false" } }
    }]
  })
}
