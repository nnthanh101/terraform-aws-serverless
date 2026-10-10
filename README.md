# terraform-aws-serverless

Terraform modules for a serverless web application on AWS, published to the Terraform Registry as `nnthanh101/serverless/aws`.

| Submodule | What it builds |
|---|---|
| `serverless-web-app` | a Lambda function behind an HTTP API, its versioned files bucket and key, the signing key, alarms, and a CloudFront site that also routes `/api/*` |
| `account-baseline` | one account standardised and hardened with no AWS Organizations: state bucket, budget, audit trail, password policy, S3 public access block, EBS and IMDSv2 defaults, and GitHub OIDC roles for one repository (reuses an existing OIDC provider) |
| `bootstrap` | one account's state bucket (S3 native locking), budget, and GitHub OIDC plan and apply roles; `account_mode = "single"` needs no AWS Organizations |
| `security-baseline` | a CloudTrail trail, its encrypted log bucket, alarms and the alerts topic; `trail_scope = "account"` needs no AWS Organizations |
| `github-oidc` | the account's GitHub OIDC provider and roles |

## Use

```hcl
module "app" {
  source  = "nnthanh101/serverless/aws//modules/serverless-web-app"
  version = "0.1.0"
  # inputs: see modules/serverless-web-app/README.md
}
```

`examples/serverless-app` is a working caller; it uses a relative path so it can be tested before a release.
Pin an exact version. Each version is tested with `terraform test` on a mocked provider before it is published.

## Where this comes from

This repository is generated from release `dev:88b31aa41391535c193e980f1336622d9d0a7935` of the maintainer's private module library and is not edited by hand: a
change is made there and arrives with its next release (see `NOTICE` and `CHANGELOG.md`). Licensed under Apache-2.0.
