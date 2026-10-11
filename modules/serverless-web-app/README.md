# serverless-web-app module

One web app on AWS from settings alone: a Lambda function behind an HTTP API, a private versioned bucket with its own key for the app's files, the token signing key (a Secrets Manager secret, or a Parameter Store parameter another root applies), CloudWatch alarms to a topic, and a static site on a private bucket behind CloudFront that also routes `/api/*` to the API, so browser and API share one origin. An AWS WAF web ACL for the site is a switch, off by default.

The calling root holds only settings, the `aws` provider (`allowed_account_ids`, `default_tags`), the backend and one module call. Tags come from the provider's `default_tags`, so the module takes no tag input; keys are lower-case kebab-case (library 5.0.0).

## What it builds

- **Function** (`main.tf`): execution role under `/<workload_role_path>/<environment>/` with the permissions boundary, log group, function with a published version behind the `live` alias, reserved concurrency.
- **API** (`main.tf`): HTTP API with the `$default` stage, access logs, throttling and an optional JWT authorizer.
- **Signing key** (`main.tf`): generated once through a write-only argument, so it never reaches state; or only a read grant on the named parameter.
- **Files** (`s3.tf`): private bucket, SSE-KMS with its own rotating key, versioning, TLS 1.2 minimum, and the function's read and write grant.
- **Site** (`cdn.tf`, `site.tf`): private bucket, origin access control, security headers, optional web ACL (created in `us-east-1`), and a digest of the site's files so a front-end-only change is a plan with changes.
- **Alarms** (`alarms.tf`): function errors, throttles and p95 duration; API 5xx and p95 latency.

## Usage

```hcl
module "app" {
  source = "git::https://<host>/<owner>/<repository>.git//modules/serverless-web-app?ref=<a 40-character commit>"

  account_id               = var.account_id
  region                   = var.region
  environment              = var.environment
  service                  = var.service
  permissions_boundary_arn = var.permissions_boundary_arn
  alarm_topic_arn          = var.alarm_topic_arn
  package_zip_path         = "${path.root}/dist/api.zip" # or source_dir, a folder this module zips into build_dir
  site_source_dir          = "${path.root}/front-end"
  environment_variables    = { S3DB_KEY = "app.db", DATABASE_PATH = "app.db" }
}
```

A complete caller, with the provider block, is in `examples/minimal`.

## Protected data

The files bucket (`aws_s3_bucket.files`) and its KMS key (`aws_kms_key.files`) carry `lifecycle { prevent_destroy = true }`, written in the module and not switchable by an input: they hold the students' data (change 0052), and losing the key loses the files. Any plan that destroys or replaces either is refused by Terraform. To retire an environment on purpose, the owner removes the protection in a reviewed change to the module first.

## Architecture

Lambda runs on `arm64` by default. `x86_64` is refused unless `architecture_exception` states the reason. Tags come from the caller's provider `default_tags`; the module has no provider block and no hard-coded Region or account (the CloudFront web ACL is created in `us-east-1`, which CloudFront requires).

## Who applies it

The calling root's owner, from their own terminal or the delivery pipeline's apply role; a pull request only tests it. The apply role needs the permissions that the resources above list; the permissions boundary must be the environment's own.

## Tests

`task test:tier1 MODULE=serverless-web-app`: plan-only, mocked providers, no credentials (plan-only, mocked providers).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_archive"></a> [archive](#requirement\_archive) | >= 2.7, < 3.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28, < 7.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | >= 3.7, < 4.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_apigatewayv2_api.http](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_api) | resource |
| [aws_apigatewayv2_authorizer.jwt](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_authorizer) | resource |
| [aws_apigatewayv2_integration.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_integration) | resource |
| [aws_apigatewayv2_route.default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_route) | resource |
| [aws_apigatewayv2_stage.default](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_stage) | resource |
| [aws_cloudfront_distribution.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_distribution) | resource |
| [aws_cloudfront_origin_access_control.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_origin_access_control) | resource |
| [aws_cloudfront_response_headers_policy.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudfront_response_headers_policy) | resource |
| [aws_cloudwatch_log_group.access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_metric_alarm.alarm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_iam_role.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.files](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.secret_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_kms_alias.files](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.files](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_lambda_alias.live](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_alias) | resource |
| [aws_lambda_function.app](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function) | resource |
| [aws_lambda_permission.api](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission) | resource |
| [aws_s3_bucket.files](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.files](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.files](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_ownership_controls.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.files](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.files](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.files](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.files](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_bucket_versioning.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_secretsmanager_secret.secret_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.secret_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_wafv2_web_acl.site](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl) | resource |
| [random_password.secret_key](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [terraform_data.site_content](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_account_id"></a> [account\_id](#input\_account\_id) | AWS account for this environment. It makes the bucket names unique and builds the key policy and the parameter ARN; the calling root's provider sets allowed\_account\_ids to it. | `string` | n/a | yes |
| <a name="input_alarm_topic_arn"></a> [alarm\_topic\_arn](#input\_alarm\_topic\_arn) | SNS topic that receives alarm and recovery notifications. | `string` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name. It is part of every resource name. | `string` | n/a | yes |
| <a name="input_permissions_boundary_arn"></a> [permissions\_boundary\_arn](#input\_permissions\_boundary\_arn) | This environment's entry in the workload\_boundary\_policy\_arns output of the bootstrap module. The apply role creates only roles that carry its own environment's boundary. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS Region for this environment. There is no default. It builds the parameter ARN and the S3 endpoint the files key may be used through. | `string` | n/a | yes |
| <a name="input_service"></a> [service](#input\_service) | Service name: the first part of every resource name ('<service>-<environment>-<purpose>'). | `string` | n/a | yes |
| <a name="input_site_source_dir"></a> [site\_source\_dir](#input\_site\_source\_dir) | Folder with the site's front-end files. Its digest is an input, so a site-only change is a plan with changes. The calling root passes a path that resolves from where terraform runs. | `string` | n/a | yes |
| <a name="input_alarm_latency_p95_ms"></a> [alarm\_latency\_p95\_ms](#input\_alarm\_latency\_p95\_ms) | API p95 latency, in milliseconds, that raises the latency alarm. | `number` | `1000` | no |
| <a name="input_architecture"></a> [architecture](#input\_architecture) | Lambda instruction set. arm64 costs about 20% less per GB-second; x86\_64 needs architecture\_exception. | `string` | `"arm64"` | no |
| <a name="input_architecture_exception"></a> [architecture\_exception](#input\_architecture\_exception) | Why this function runs on x86\_64 instead of arm64: the reason, or the spec's exception id. Null for arm64. | `string` | `null` | no |
| <a name="input_build_dir"></a> [build\_dir](#input\_build\_dir) | Folder where the zip of source\_dir is written. Null writes <root module folder>/.build. Ignored with package\_zip\_path. The calling root passes a path that resolves from where terraform runs. | `string` | `null` | no |
| <a name="input_environment_variables"></a> [environment\_variables](#input\_environment\_variables) | The app's own environment variables. SERVICE, ENVIRONMENT, S3DB\_BUCKET, CORS\_ORIGIN and the signing key's name are set by this module and win over a key of the same name. | `map(string)` | `{}` | no |
| <a name="input_files_kms_key"></a> [files\_kms\_key](#input\_files\_kms\_key) | false uses S3-managed encryption at no cost; true adds a customer-managed key, about 1 USD a month, with key-level access control and audit. | `bool` | `true` | no |
| <a name="input_handler"></a> [handler](#input\_handler) | Handler entry point, for example handler.handler for Python or index.handler for Node.js. | `string` | `"handler.handler"` | no |
| <a name="input_image_uri"></a> [image\_uri](#input\_image\_uri) | ECR image that the function runs as a container image, pinned by digest (<account>.dkr.ecr.<region>.amazonaws.com/<name>@sha256:<64 hex>) so a tag can never move it. Null (the default) deploys the zip from source\_dir or package\_zip\_path; when set, neither is needed and runtime and handler are not used. | `string` | `null` | no |
| <a name="input_jwt_audience"></a> [jwt\_audience](#input\_jwt\_audience) | Accepted JWT audiences (client IDs). Required when jwt\_issuer is set. | `list(string)` | `[]` | no |
| <a name="input_jwt_issuer"></a> [jwt\_issuer](#input\_jwt\_issuer) | Optional JWT issuer URL (for example an Amazon Cognito user pool or another OIDC provider). Null leaves the API open. | `string` | `null` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Days to keep CloudWatch logs. Storage is billed per GB-month, so longer retention costs more. | `number` | `30` | no |
| <a name="input_memory_mb"></a> [memory\_mb](#input\_memory\_mb) | Lambda memory in MB. CPU scales with memory; duration cost is memory x time. | `number` | `512` | no |
| <a name="input_package_zip_path"></a> [package\_zip\_path](#input\_package\_zip\_path) | A zip that is already built; it is deployed as it is and nothing is archived. Set this or source\_dir, not both. Not used when image\_uri is set. | `string` | `null` | no |
| <a name="input_reserved_concurrency"></a> [reserved\_concurrency](#input\_reserved\_concurrency) | Concurrent executions reserved for the function. Small, so one function cannot take the account's pool; a stale write is refused by the app's conditional put, not by this number. Null reserves nothing, for an account whose concurrency limit leaves no room to reserve. | `number` | `4` | no |
| <a name="input_runtime"></a> [runtime](#input\_runtime) | Lambda runtime. tflint rejects deprecated runtimes; these three are current. | `string` | `"python3.13"` | no |
| <a name="input_secret_store"></a> [secret\_store](#input\_secret\_store) | Where the token signing key lives. secrets-manager (the default) creates and writes the secret in this module. parameter-store reads the SecureString that the owner applies in a separate root: this module creates no secret and only grants read on its name. environment generates the key here and sets it as the SECRET\_KEY environment variable of the function, with no secret store and no read permission; the trade-off is that the value is in state and visible to anyone allowed lambda:GetFunctionConfiguration. | `string` | `"secrets-manager"` | no |
| <a name="input_site_content_security_policy"></a> [site\_content\_security\_policy](#input\_site\_content\_security\_policy) | Content-Security-Policy header that CloudFront adds to every response. | `string` | `"default-src 'self'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'; base-uri 'self'"` | no |
| <a name="input_site_excluded_files"></a> [site\_excluded\_files](#input\_site\_excluded\_files) | Files in site\_source\_dir that the pipeline does not upload (container and local preview files). | `list(string)` | <pre>[<br/>  "_nocache_server.py",<br/>  "Dockerfile",<br/>  "nginx.conf",<br/>  ".dockerignore"<br/>]</pre> | no |
| <a name="input_site_price_class"></a> [site\_price\_class](#input\_site\_price\_class) | CloudFront edge locations for the site. PriceClass\_100 (North America and Europe) is the cheapest. | `string` | `"PriceClass_100"` | no |
| <a name="input_site_rate_limit"></a> [site\_rate\_limit](#input\_site\_rate\_limit) | Requests per client IP in any 5-minute window before AWS WAF blocks it. | `number` | `2000` | no |
| <a name="input_site_waf_enabled"></a> [site\_waf\_enabled](#input\_site\_waf\_enabled) | Attach an AWS WAF web ACL with the AWS common rule set and a per-IP rate limit. Adds a fixed monthly charge. | `bool` | `false` | no |
| <a name="input_source_dir"></a> [source\_dir](#input\_source\_dir) | Folder with the built handler, zipped by this module. The calling root passes a path that resolves from where terraform runs. Set this or package\_zip\_path, not both. Not used when image\_uri is set. | `string` | `null` | no |
| <a name="input_throttle_burst_limit"></a> [throttle\_burst\_limit](#input\_throttle\_burst\_limit) | Short burst of requests the API accepts above the steady rate. | `number` | `100` | no |
| <a name="input_throttle_rate_limit"></a> [throttle\_rate\_limit](#input\_throttle\_rate\_limit) | Steady-state requests per second for the whole API, before API Gateway returns 429. | `number` | `50` | no |
| <a name="input_timeout_seconds"></a> [timeout\_seconds](#input\_timeout\_seconds) | Lambda timeout in seconds. | `number` | `15` | no |
| <a name="input_workload_role_path"></a> [workload\_role\_path](#input\_workload\_role\_path) | IAM path segment for workload roles; roles sit under /<path>/<environment>/, as the bootstrap module expects. | `string` | `"workload"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alias_arn"></a> [alias\_arn](#output\_alias\_arn) | ARN of the 'live' alias that serves traffic. |
| <a name="output_api_id"></a> [api\_id](#output\_api\_id) | HTTP API ID. |
| <a name="output_files_bucket"></a> [files\_bucket](#output\_files\_bucket) | Bucket that holds the application's files (the students' data). It cannot be destroyed through this module. |
| <a name="output_files_kms_key_arn"></a> [files\_kms\_key\_arn](#output\_files\_kms\_key\_arn) | Customer managed key that encrypts the files bucket, or null when files\_kms\_key is false. It cannot be destroyed through this module. |
| <a name="output_function_name"></a> [function\_name](#output\_function\_name) | Lambda function name. |
| <a name="output_function_role_arn"></a> [function\_role\_arn](#output\_function\_role\_arn) | Execution role of the function. |
| <a name="output_site_bucket"></a> [site\_bucket](#output\_site\_bucket) | Bucket that CI uploads the built site to. |
| <a name="output_site_distribution_id"></a> [site\_distribution\_id](#output\_site\_distribution\_id) | CloudFront distribution that CI invalidates after it uploads the site. |
| <a name="output_site_url"></a> [site\_url](#output\_site\_url) | HTTPS address of the static site. |
| <a name="output_url"></a> [url](#output\_url) | HTTPS address of the API ($default stage). |
<!-- END_TF_DOCS -->
