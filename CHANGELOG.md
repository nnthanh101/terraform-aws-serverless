# Changelog

Each public version is generated from one library release (conventional commits, semantic versions).

## 0.4.0 (2026-10-11)

Public 0.4.0 generated from library release terraform-aws-v5.3.0 (commit 89b3963). The modules are
serverless-web-app, bootstrap, security-baseline, github-oidc, account-baseline.

## What 0.4.0 adds to serverless-web-app

Every new input keeps the earlier behaviour by default, so an existing caller plans with no changes.

- `image_uri`: run a Lambda container image pinned by digest (for example an app with the AWS Lambda Web Adapter).
- `secret_store = "environment"`: Terraform generates the signing key and passes it as an encrypted environment variable.
- `reserved_concurrency = null`: no reserved concurrency, for an account still at the default Lambda limit.
- `files_kms_key = false`: S3-managed encryption for the data bucket, with no customer-managed key to pay for.
- `files_bucket_label`: the word in the data bucket's name, `<prefix>-<label>-<account>`.

Each input has plan-only tests in `modules/serverless-web-app/tests/unit.tftest.hcl`.
