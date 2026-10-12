# terraform-aws-serverless

Terraform modules for a serverless web application on AWS, published to the Terraform Registry as `nnthanh101/serverless/aws`.

| Submodule | What it builds |
|---|---|
| `serverless-web-app` | a Lambda function behind an HTTP API, its versioned files bucket and key, the signing key, alarms, and a CloudFront site that also routes `/api/*` |
| `account` | one AWS account, in or out of AWS Organizations, safe and deployable in one call: state bucket, budget and GitHub OIDC roles for your repositories (reuses an existing OIDC provider), with an optional audit trail, password policy, S3 public access block, and EBS and IMDSv2 defaults; for an Organizations member it can also manage default VPCs, a Lambda quota and Resource Explorer |
| `bootstrap` | one account's state bucket (S3 native locking), budget, and GitHub OIDC plan and apply roles; `account_mode = "single"` needs no AWS Organizations |
| `security-baseline` | a CloudTrail trail, its encrypted log bucket, alarms and the alerts topic; `trail_scope = "account"` needs no AWS Organizations |

## Use

```hcl
module "app" {
  source  = "nnthanh101/serverless/aws//modules/serverless-web-app"
  version = "0.5.0"
  # inputs: see modules/serverless-web-app/README.md
}
```

`examples/serverless-app` is a working caller; it uses a relative path so it can be tested before a release.
Pin an exact version. Each version is tested with `terraform test` on a mocked provider before it is published.

## Where this comes from

This repository is generated from release `terraform-aws-v5.6.0` of the maintainer's private module library and is not edited by hand: a
change is made there and arrives with its next release (see `NOTICE` and `CHANGELOG.md`). Licensed under Apache-2.0.
