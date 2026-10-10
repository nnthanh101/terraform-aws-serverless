# account-baseline

One AWS account, standardised and hardened, with no AWS Organizations. Apply it once; every app deployed afterwards sits on it.

| Control | How |
|---|---|
| State bucket: versioned, encrypted, public access blocked, TLS 1.2+ only, S3-native locking | `bootstrap` |
| Monthly budget alarm to an email (80%, 100%, forecast over 100%) | `bootstrap` |
| Audit trail to its own encrypted bucket and log group, alarms, alerts topic | `security-baseline` (`trail_scope = "account"`) |
| IAM password policy, account-wide S3 public access block, EBS encryption by default | `security-baseline` |
| IMDSv2 required by default for new instances | `security-baseline/modules/account-guardrails` |
| GitHub OIDC plan and apply roles that trust ONE repository and its environments; an existing OIDC provider is reused through an input | `bootstrap` |
| A permissions boundary per environment, and the deny of dev against production's resources, state and saved plans | `bootstrap` |

The module holds no resource of its own; it wires the three submodules of this repository so they agree on names and order.

## Use

```hcl
module "account" {
  source = "../../modules/account-baseline"   # registry: nnthanh101/serverless/aws//modules/account-baseline

  account_id         = "123456789012"
  region             = "ap-southeast-2"
  github_repository  = "example-org/example-app"   # the one input to change to trust another repository
  default_branch     = "develop"
  budget_limit_usd   = 50
  notification_email = "owner@example.com"

  # existing_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
}
```

Apply from an administrator's terminal with a local backend, then `terraform init -migrate-state` into the bucket the apply made
(`backend_settings` gives its name). The outputs give each app root its `permissions_boundary_arn`, `alarm_topic_arn` and role ARNs.

A second baseline in one account (for a second tenant, or a test beside an existing one) sets `name_prefix` and `security_name_prefix`
to its own names so nothing collides (the two protection policies take their names from `security_name_prefix`: `kit-baseline` gives
`KitBaselineProtect`, derived rather than a new input because it must differ whenever the prefix does), `access_analyzer_enabled = false` when the
account already has an IAM Access Analyzer (one per Region), and `enable_api_gateway_account = false` when the Region's logging role is already set.

Tests: `terraform test` (plan-only, mocked provider, no credentials) plans every input path once and each refused value.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28, < 7.0 |

## Resources

No resources.

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_account_id"></a> [account\_id](#input\_account\_id) | The 12-digit AWS account this baseline belongs to. The plan stops when the provider signs in to any other account. | `string` | n/a | yes |
| <a name="input_budget_limit_usd"></a> [budget\_limit\_usd](#input\_budget\_limit\_usd) | Monthly cost budget for the account in US dollars. Emails go out at 80% and 100% of actual cost, and when the forecast passes 100%. | `number` | n/a | yes |
| <a name="input_default_branch"></a> [default\_branch](#input\_default\_branch) | The repository's default branch. Only the plan role for the default branch trusts it. | `string` | n/a | yes |
| <a name="input_github_repository"></a> [github\_repository](#input\_github\_repository) | The one GitHub repository the plan and apply roles trust, as <organisation>/<repository>. Change this one value to point the account at another repository. | `string` | n/a | yes |
| <a name="input_notification_email"></a> [notification\_email](#input\_notification\_email) | Address that receives the budget messages. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | The account's home Region: the state bucket, the trail, the alarms and the per-Region defaults live here. There is no default. | `string` | n/a | yes |
| <a name="input_access_analyzer_enabled"></a> [access\_analyzer\_enabled](#input\_access\_analyzer\_enabled) | Create the account's IAM Access Analyzer. An account may hold only one per Region: set false when it already has one. | `bool` | `true` | no |
| <a name="input_alert_email"></a> [alert\_email](#input\_alert\_email) | Address that receives the security alarms (AWS sends a confirmation first). Null uses notification\_email. | `string` | `null` | no |
| <a name="input_change_id"></a> [change\_id](#input\_change\_id) | Four-digit change record number for the change tag, or null for none. | `string` | `null` | no |
| <a name="input_create_state_kms_key"></a> [create\_state\_kms\_key](#input\_create\_state\_kms\_key) | true encrypts state and saved plans with a customer-managed key (about 1 USD a month). false (the default) uses the bucket's AES-256 default: still encrypted at rest and reachable only over TLS. | `bool` | `false` | no |
| <a name="input_enable_api_gateway_account"></a> [enable\_api\_gateway\_account](#input\_enable\_api\_gateway\_account) | Set the account's API Gateway logging role in this Region. Set false when another stack in this account and Region already manages it. | `bool` | `true` | no |
| <a name="input_environments"></a> [environments](#input\_environments) | The environments deployed into this account. Each gets an apply role that trusts only its GitHub Environment. | `list(string)` | <pre>[<br/>  "dev",<br/>  "production"<br/>]</pre> | no |
| <a name="input_existing_oidc_provider_arn"></a> [existing\_oidc\_provider\_arn](#input\_existing\_oidc\_provider\_arn) | ARN of the account's GitHub OIDC provider when it already has one (an account holds only one). Null creates it. | `string` | `null` | no |
| <a name="input_github_owner_id"></a> [github\_owner\_id](#input\_github\_owner\_id) | Numeric id of the repository's owner (gh api users/<org> --jq .id). When set, the roles also require it. | `string` | `null` | no |
| <a name="input_github_repository_id"></a> [github\_repository\_id](#input\_github\_repository\_id) | Numeric id of github\_repository (gh api repos/<org>/<repo> --jq .id). When set, the roles also require it, so a renamed or re-created repository cannot reuse the trust. | `string` | `null` | no |
| <a name="input_github_subject_prefix"></a> [github\_subject\_prefix](#input\_github\_subject\_prefix) | The repository's OIDC subject prefix when it is not repo:<org>/<repo> (gh api repos/<org>/<repo>/actions/oidc/customization/sub --jq .sub\_claim\_prefix). Repositories created after 2026-07-15 use repo:<org>@<id>/<repo>@<id>. | `string` | `null` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix of the delivery role names (<prefix>-plan-pr, <prefix>-plan-default, <prefix>-apply-<environment>). Any value other than gha is also put in front of the boundary, budget and state bucket names, so a second baseline in one account never collides with the first. | `string` | `"gha"` | no |
| <a name="input_production_environments"></a> [production\_environments](#input\_production\_environments) | The entries of environments that are production. Every other environment is denied their resources, their state and the saved plans. Must name at least one. | `list(string)` | <pre>[<br/>  "production"<br/>]</pre> | no |
| <a name="input_security_name_prefix"></a> [security\_name\_prefix](#input\_security\_name\_prefix) | Prefix of the security baseline's own resources (trail, buckets, alerts topic). The delivery roles are denied changes to everything it names. | `string` | `"security-baseline-shared"` | no |
| <a name="input_access_log_bucket_enabled"></a> [access\_log\_bucket\_enabled](#input\_access\_log\_bucket\_enabled) | Create the second bucket that receives the trail bucket's S3 server access logs. It costs S3 storage and requests for as long as the logs are kept. | `bool` | `true` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Days the trail keeps its log files and log events: 90, 400 or longer. The log group costs $0.50 per GB ingested in ap-southeast-6, and storage grows with the days kept. | `number` | `400` | no |
| <a name="input_security_kms_key_enabled"></a> [security\_kms\_key\_enabled](#input\_security\_kms\_key\_enabled) | Create the security baseline's customer-managed key. It costs $1.00 per key version per month plus requests. False encrypts the trail bucket with S3-managed keys and creates no key. | `bool` | `true` | no |
| <a name="input_service"></a> [service](#input\_service) | Name base of the account-level resources, <service>-<environment>-workload-boundary and <service>-shared-monthly-cost. | `string` | `"platform"` | no |
| <a name="input_state_bucket_name"></a> [state\_bucket\_name](#input\_state\_bucket\_name) | Name of the state bucket. Null uses <account\_id>-tfstate-<region> (with the name\_prefix in front of tfstate when it is not gha). | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Extra tags for resources that take tags. Keys are lower-case kebab-case. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alerts_topic_arn"></a> [alerts\_topic\_arn](#output\_alerts\_topic\_arn) | The SNS topic that receives the security alarms: alarm\_topic\_arn of every app in this account. |
| <a name="output_apply_role_arns"></a> [apply\_role\_arns](#output\_apply\_role\_arns) | One apply role per environment; each trusts only its GitHub Environment. |
| <a name="output_apply_role_names"></a> [apply\_role\_names](#output\_apply\_role\_names) | One apply role name per environment (<name\_prefix>-apply-<environment>). |
| <a name="output_backend_settings"></a> [backend\_settings](#output\_backend\_settings) | Values for the state backend of every root in this account (add key = "<app>/<environment>/terraform.tfstate"). |
| <a name="output_budget_name"></a> [budget\_name](#output\_budget\_name) | The monthly account budget. |
| <a name="output_controls"></a> [controls](#output\_controls) | Which controls this account has, one boolean each. |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | The GitHub OIDC provider the roles trust: the one this module created, or existing\_oidc\_provider\_arn. |
| <a name="output_plan_role_arns"></a> [plan\_role\_arns](#output\_plan\_role\_arns) | Read-only plan roles: pr (pull requests) and default (the default branch, which saves the production plan). |
| <a name="output_protect_policy_names"></a> [protect\_policy\_names](#output\_protect\_policy\_names) | The names of the two deny-only policies on the apply roles; they follow security\_name\_prefix (SecurityBaselineProtect by default). |
| <a name="output_region_defaults"></a> [region\_defaults](#output\_region\_defaults) | The per-Region defaults: EBS encryption and the IMDS token mode. |
| <a name="output_state_bucket_name"></a> [state\_bucket\_name](#output\_state\_bucket\_name) | The state bucket. |
| <a name="output_trail_arn"></a> [trail\_arn](#output\_trail\_arn) | The audit trail. |
| <a name="output_trail_bucket_name"></a> [trail\_bucket\_name](#output\_trail\_bucket\_name) | The bucket that holds the trail's log files. |
| <a name="output_workload_boundary_policy_arns"></a> [workload\_boundary\_policy\_arns](#output\_workload\_boundary\_policy\_arns) | The permissions boundary per environment: permissions\_boundary\_arn of that environment's app. |
<!-- END_TF_DOCS -->
