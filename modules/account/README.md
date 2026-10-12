# account

A new AWS account, in or out of AWS Organizations, is safe and deployable in one call.

One call builds the account's state bucket and key, keyless CI plan and apply roles (GitHub or Azure DevOps) with a permissions boundary per environment, and a monthly budget that emails the alert mailbox (the library's `../bootstrap`). Optionally (`security_baseline = true`) it adds the audit trail, alarms, IAM password policy, account-wide S3 public access block, EBS encryption and IMDSv2 by default (`../security-baseline`, `trail_scope = "account"`). For an Organizations member it also manages the account-level settings: default VPCs, a Lambda concurrency quota and Resource Explorer indexes.

The calling root holds the settings, the `aws` provider (`assume_role` into a member account, `allowed_account_ids`, `default_tags`), the backend and one module call. The module has no provider block and no hard-coded Region or account.

## What it builds

| Part | File | When |
|---|---|---|
| State bucket and key, plan and apply roles, boundary per environment, budget | `main.tf` (`module "bootstrap"`) | always |
| Audit trail, alarms, alerts topic, password policy, S3 public access block, EBS and IMDSv2 defaults | `main.tf` (`module "security"`) | `security_baseline = true` |
| Account check: the plan runs in `account_id`, and the workspace is named after it (`require_account_workspace`) | `main.tf` | always |
| Default VPCs: `default_vpcs` is `keep` (default), `adopt` or `remove`; `adopt` and `remove` are refused in the management account and need `allowed_regions` | `default-vpcs.tf` | Organizations member |
| Lambda quota: `lambda_concurrency_quota` is 0 (no request) or 1000 to 20000; a request is one-way | `lambda-quota.tf` | Organizations member |
| Resource Explorer: `resource_explorer` creates a LOCAL index in each allowed Region | `resource-explorer.tf` | Organizations member |

## Use: an Organizations member account

```hcl
provider "aws" {
  region              = var.region
  allowed_account_ids = [var.account_id]
  assume_role {
    role_arn     = "arn:aws:iam::${var.account_id}:role/OrganizationAccountAccessRole"
    session_name = "account-bootstrap"
  }
  default_tags { tags = var.tags }
}

module "account" {
  source = "git::https://<host>/<owner>/<repository>.git//modules/account?ref=<a 40-character commit>"
  # inputs: see examples/minimal
}

# The module cannot hold this: an import block is allowed only in the root module.
import {
  for_each = module.account.default_igw_ids
  to       = module.account.aws_internet_gateway.this[each.key]
  id       = "${each.value}@${each.key}"
}
```

The caller keeps the `import` block (without it, `default_vpcs = "adopt"` plans to create an internet gateway the default VPC already has), the provider's `assume_role` and `allowed_account_ids` (so `assume_role_arn` is not an output), and the backend (state bucket, key and workspace per account). The owner applies it from their own terminal, signed in to the management account; a pull request only tests it.

## Use: a standalone account (no AWS Organizations)

```hcl
module "account" {
  source = "nnthanh101/serverless/aws//modules/account"   # or ../../modules/account

  account_id                = "123456789012"
  region                    = "ap-southeast-2"
  github_repositories       = ["example-org/example-app"]   # a list; add github_repository_ids and github_subject_prefixes in the same order
  default_branch            = "develop"
  budget_limit_usd          = 50
  notification_email        = "owner@example.com"
  account_mode              = "single"
  environments              = ["dev", "production"]
  production_environments   = ["production"]
  security_baseline         = true
  create_state_kms_key      = false
  require_account_workspace = false
}
```

Apply from an administrator's terminal with a local backend, then `terraform init -migrate-state` into the bucket the apply made (`backend_settings` gives its name). The outputs give each app root its `permissions_boundary_arn`, `alerts_topic_arn` and role ARNs.

A second tenant in one account sets `name_prefix` and `security_name_prefix` to its own names so nothing collides (the two protection policies take their names from `security_name_prefix`: `kit-baseline` gives `KitBaselineProtect`), `access_analyzer_enabled = false` when the account already has an IAM Access Analyzer (one per Region), `existing_oidc_provider_arn` when the account already has the OIDC provider, and `enable_api_gateway_account = false` when the Region's logging role is already set.

### Moving from account-baseline

A caller of the retired `account-baseline` module changes its source to `modules/account` and states these inputs, which `account-baseline` fixed or defaulted:

- `security_baseline = true` (required, no default) and `account_mode = "single"`.
- `create_state_kms_key = false`, unless its state bucket was made with a key (then `true`). `account-baseline` defaulted to no key; this module defaults to a key.
- `change_id` (required) and `require_account_workspace = false`.
- One-item lists in place of the scalars: `github_repositories = ["org/repo"]`, `github_repository_ids = ["123"]`, `github_subject_prefixes = ["repo:org/repo"]`.
- `environments` and `production_environments` (no defaults here; `account-baseline` defaulted to `["dev", "production"]` and `["production"]`).

The state keeps its addresses: `module.security` becomes `module.security[0]` and the IMDSv2 object follows through `moved` blocks, so the first plan shows no change.

### Standalone values

A standalone account creates none of the Organizations-only settings with these values (all are the defaults):

| Input | Value | Effect |
|---|---|---|
| `default_vpcs` | `"keep"` | no default VPC resource; the data sources, the management-account guard and `allowed_regions` are not read |
| `allowed_regions` | `[]` | nothing is touched per Region |
| `management_account_id` | `null` | needed only by `adopt` and `remove` |
| `lambda_concurrency_quota` | `0` | no quota request |
| `resource_explorer` | `false` | no index |
| `account_mode` | `"single"` | one account holds every environment; `production_environments` must name at least one |
| `require_account_workspace` | `false` | a local-backend first apply runs in the default workspace |
| `security_baseline` | `true` | the audit trail, alarms and account hardening a standalone account has no organization to give it |

`create_state_kms_key` defaults to `true` (the stricter choice); a standalone account that wants no key cost sets `false`.

## Tests

`task test:tier1 MODULE=account`: plan-only, mocked providers, no credentials. `tests/member-account.tftest.hcl` and `tests/azure-devops.tftest.hcl` cover the member mode; `tests/standalone.tftest.hcl` and `tests/azure-devops-standalone.tftest.hcl` the standalone mode.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28, < 7.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_default_subnet.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_subnet) | resource |
| [aws_default_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_vpc) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_resourceexplorer2_index.local](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/resourceexplorer2_index) | resource |
| [aws_servicequotas_service_quota.lambda_concurrency](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/servicequotas_service_quota) | resource |
| [terraform_data.management_account_guard](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_account_id"></a> [account\_id](#input\_account\_id) | The account: for an Organizations member, as the organization lists it: aws organizations list-accounts. The calling root's provider assumes a role in this account and sets allowed\_account\_ids to it. | `string` | n/a | yes |
| <a name="input_account_mode"></a> [account\_mode](#input\_account\_mode) | single: this account holds every environment (a workload account); landing-zone: one account per environment (a sandbox). | `string` | n/a | yes |
| <a name="input_budget_limit_usd"></a> [budget\_limit\_usd](#input\_budget\_limit\_usd) | Monthly budget in US dollars, set by the budget owner. Alerts at 80% and 100% of actual cost and on a forecast over 100%; credits are left out. | `number` | n/a | yes |
| <a name="input_change_id"></a> [change\_id](#input\_change\_id) | The change record this apply belongs to, four digits, written to the change tag. | `string` | n/a | yes |
| <a name="input_default_branch"></a> [default\_branch](#input\_default\_branch) | The repositories' default branch, read from the repository settings. | `string` | n/a | yes |
| <a name="input_environments"></a> [environments](#input\_environments) | The environments this account holds; each gets an apply role that trusts only its GitHub Environment. | `list(string)` | n/a | yes |
| <a name="input_notification_email"></a> [notification\_email](#input\_notification\_email) | The watched mailbox for budget alerts (kept in the caller's untracked environment, never in a tracked file). | `string` | n/a | yes |
| <a name="input_production_environments"></a> [production\_environments](#input\_production\_environments) | The entries of environments that are production; [] for an account that holds none (account\_mode = landing-zone). | `list(string)` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | The member account's Region. Set it to the Region of the calling root's provider. There is no default. | `string` | n/a | yes |
| <a name="input_security_baseline"></a> [security\_baseline](#input\_security\_baseline) | Also apply the account's security baseline (modules/security-baseline): audit trail, alarms, IAM password policy, S3 public access block, EBS encryption and IMDSv2 by default. Required, so a caller states it: true for a standalone account (the former account-baseline), false for an Organizations member, which gets these from the organization. | `bool` | n/a | yes |
| <a name="input_access_analyzer_enabled"></a> [access\_analyzer\_enabled](#input\_access\_analyzer\_enabled) | Create the account's IAM Access Analyzer. An account may hold only one per Region: set false when it already has one. Used only with security\_baseline = true. | `bool` | `true` | no |
| <a name="input_access_log_bucket_enabled"></a> [access\_log\_bucket\_enabled](#input\_access\_log\_bucket\_enabled) | Create the second bucket that receives the trail bucket's S3 server access logs. It costs S3 storage and requests for as long as the logs are kept. Used only with security\_baseline = true. | `bool` | `true` | no |
| <a name="input_ado_apply_service_connections"></a> [ado\_apply\_service\_connections](#input\_ado\_apply\_service\_connections) | Per environment, the service connections its apply role trusts. Only with ci\_platform = azure-devops. | <pre>map(list(object({<br/>    project = string<br/>    name    = string<br/>  })))</pre> | `{}` | no |
| <a name="input_ado_organization_id"></a> [ado\_organization\_id](#input\_ado\_organization\_id) | Azure DevOps organization GUID (lower-case). Only with ci\_platform = azure-devops. | `string` | `null` | no |
| <a name="input_ado_organization_name"></a> [ado\_organization\_name](#input\_ado\_organization\_name) | Azure DevOps organization name, the first segment of the subject sc://<organization>/<project>/<connection>. Only with ci\_platform = azure-devops. | `string` | `null` | no |
| <a name="input_ado_plan_service_connections"></a> [ado\_plan\_service\_connections](#input\_ado\_plan\_service\_connections) | Service connections the plan roles trust, each { project, name }. Only with ci\_platform = azure-devops. | <pre>list(object({<br/>    project = string<br/>    name    = string<br/>  }))</pre> | `[]` | no |
| <a name="input_alert_email"></a> [alert\_email](#input\_alert\_email) | Address that receives the security alarms (AWS sends a confirmation first). Null uses notification\_email. Used only with security\_baseline = true. | `string` | `null` | no |
| <a name="input_allowed_regions"></a> [allowed\_regions](#input\_allowed\_regions) | The Regions member accounts may use. The default VPCs are removed in these Regions only; the Region policy blocks the others. | `list(string)` | `[]` | no |
| <a name="input_apply_workflow_refs"></a> [apply\_workflow\_refs](#input\_apply\_workflow\_refs) | Per environment, the only workflows allowed to apply: <organisation>/<repository>/.github/workflows/<file>@<ref>. | `map(list(string))` | `{}` | no |
| <a name="input_ci_platform"></a> [ci\_platform](#input\_ci\_platform) | The pipeline platform the roles trust: github (default) or azure-devops. See the bootstrap module. | `string` | `"github"` | no |
| <a name="input_container_repositories"></a> [container\_repositories](#input\_container\_repositories) | Names of container image registries (ECR) to create in this account. Empty creates none. | `list(string)` | `[]` | no |
| <a name="input_create_state_kms_key"></a> [create\_state\_kms\_key](#input\_create\_state\_kms\_key) | true: the account's state bucket gets a customer-managed KMS key (about 1 USD a month: key policy as a second lock, a CloudTrail line per decrypt, one-edit revocation). false: SSE-S3, no key and no cost. The default is the key, the stricter choice. | `bool` | `true` | no |
| <a name="input_default_vpcs"></a> [default\_vpcs](#input\_default\_vpcs) | What Terraform does with the default VPC in each allowed Region. keep: manages none and never deletes (the default; the caller must refuse it once any was adopted). adopt: manages each one with force\_destroy, nothing is deleted yet. remove: manages none, so the plan shows each adopted default VPC destroyed (adopt first, then remove; see default-vpcs.tf). adopt and remove are refused in the management account. | `string` | `"keep"` | no |
| <a name="input_enable_api_gateway_account"></a> [enable\_api\_gateway\_account](#input\_enable\_api\_gateway\_account) | Set the account's API Gateway logging role in this Region. Set false when another stack in this account and Region already manages it. | `bool` | `true` | no |
| <a name="input_existing_oidc_provider_arn"></a> [existing\_oidc\_provider\_arn](#input\_existing\_oidc\_provider\_arn) | ARN of the account's OIDC provider for the ci\_platform issuer when it already has one (an account holds only one). Null creates it. | `string` | `null` | no |
| <a name="input_github_owner_id"></a> [github\_owner\_id](#input\_github\_owner\_id) | Numeric ID of the repositories' owner: gh api orgs/<organisation> --jq .id. | `string` | `null` | no |
| <a name="input_github_owner_ids"></a> [github\_owner\_ids](#input\_github\_owner\_ids) | Numeric owner IDs of github\_repositories, in the same order, when more than one organisation owns them. Not together with github\_owner\_id. | `list(string)` | `[]` | no |
| <a name="input_github_repositories"></a> [github\_repositories](#input\_github\_repositories) | <organisation>/<repository> of each repository whose pipelines deploy into this account. Required with ci\_platform = github. | `list(string)` | `[]` | no |
| <a name="input_github_repository_ids"></a> [github\_repository\_ids](#input\_github\_repository\_ids) | Numeric ID of each repository, in the same order: gh api repos/<organisation>/<repository> --jq .id. | `list(string)` | `[]` | no |
| <a name="input_github_subject_prefixes"></a> [github\_subject\_prefixes](#input\_github\_subject\_prefixes) | Each repository's OIDC subject prefix, in the same order, read from its settings and never assumed: gh api repos/<organisation>/<repository>/actions/oidc/customization/sub --jq .sub\_claim\_prefix. | `list(string)` | `[]` | no |
| <a name="input_lambda_concurrency_quota"></a> [lambda\_concurrency\_quota](#input\_lambda\_concurrency\_quota) | Requested Lambda concurrent-executions quota . 0 requests nothing; otherwise 1000 to 20000. A request is one-way: destroy does not lower it. While AWS reviews it, re-plans show a change. Set it only on a new account or after AWS grants it, then it reads the granted value and makes no second request. | `number` | `0` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Days the trail keeps its log files and log events: 90, 400 or longer. Used only with security\_baseline = true. | `number` | `400` | no |
| <a name="input_management_account_id"></a> [management\_account\_id](#input\_management\_account\_id) | The organization's management account, an input of the caller. It is read only to refuse removing default VPCs there. | `string` | `null` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix of the delivery role names (<prefix>-plan-pr, <prefix>-plan-default, <prefix>-apply-<environment>). Any value other than gha is also put in front of the boundary, budget and state bucket names, so a second tenant in one account never collides with the first. | `string` | `"gha"` | no |
| <a name="input_passrole_services"></a> [passrole\_services](#input\_passrole\_services) | Extra service principals (for example bedrock-agentcore.amazonaws.com) the apply roles may pass workload roles to. | `list(string)` | `[]` | no |
| <a name="input_require_account_workspace"></a> [require\_account\_workspace](#input\_require\_account\_workspace) | Stop a plan unless the selected workspace is named after account\_id, so each member account's state sits under its own key. Only the plan-only tests, which run in the default workspace, set it to false. | `bool` | `true` | no |
| <a name="input_resource_explorer"></a> [resource\_explorer](#input\_resource\_explorer) | Create an AWS Resource Explorer LOCAL index in each allowed Region . Off by default. Needs allowed\_regions. | `bool` | `false` | no |
| <a name="input_security_kms_key_enabled"></a> [security\_kms\_key\_enabled](#input\_security\_kms\_key\_enabled) | Create the security baseline's customer-managed key. It costs $1.00 per key version per month plus requests. False encrypts the trail bucket with S3-managed keys and creates no key. Used only with security\_baseline = true. | `bool` | `true` | no |
| <a name="input_security_name_prefix"></a> [security\_name\_prefix](#input\_security\_name\_prefix) | Prefix of the security baseline's own resources (trail, buckets, alerts topic). The delivery roles are denied changes to everything it names. Used only with security\_baseline = true. | `string` | `"security-baseline-shared"` | no |
| <a name="input_service"></a> [service](#input\_service) | Short name that starts resource names and fills the service tag. | `string` | `"platform"` | no |
| <a name="input_state_bucket_name"></a> [state\_bucket\_name](#input\_state\_bucket\_name) | Name of the state bucket. Null uses <account\_id>-tfstate-<region> (with the name\_prefix in front of tfstate when it is not gha). | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Cost tags on every resource, for example service, environment and change. | `map(string)` | `{}` | no |
| <a name="input_workload_boundary_extra_actions"></a> [workload\_boundary\_extra\_actions](#input\_workload\_boundary\_extra\_actions) | Per environment, extra enumerated read actions added to that environment's workload boundary. | `map(list(string))` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_account_id"></a> [account\_id](#output\_account\_id) | The account the plan ran in, checked against account\_id. |
| <a name="output_alerts_topic_arn"></a> [alerts\_topic\_arn](#output\_alerts\_topic\_arn) | The SNS topic that receives the security alarms (alarm\_topic\_arn of every app in this account); null without security\_baseline. |
| <a name="output_apply_role_arns"></a> [apply\_role\_arns](#output\_apply\_role\_arns) | One apply role per environment, set as that GitHub Environment's role. |
| <a name="output_apply_role_names"></a> [apply\_role\_names](#output\_apply\_role\_names) | One apply role name per environment (<name\_prefix>-apply-<environment>). |
| <a name="output_backend_settings"></a> [backend\_settings](#output\_backend\_settings) | The values for a workload root's backend.hcl in this account. |
| <a name="output_budget_name"></a> [budget\_name](#output\_budget\_name) | The monthly budget, for the spend-alert proof. |
| <a name="output_container_repository_urls"></a> [container\_repository\_urls](#output\_container\_repository\_urls) | Repository URL per container\_repositories name. |
| <a name="output_controls"></a> [controls](#output\_controls) | Which security controls this account has, one boolean each; null without security\_baseline. |
| <a name="output_default_igw_ids"></a> [default\_igw\_ids](#output\_default\_igw\_ids) | Internet gateway ID of the default VPC in each allowed Region when default\_vpcs is adopt, else empty. The calling root imports each into aws\_internet\_gateway.this (an import block is allowed only in the root module). |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | The OIDC provider the roles trust: the one this module created, or existing\_oidc\_provider\_arn. |
| <a name="output_plan_role_arns"></a> [plan\_role\_arns](#output\_plan\_role\_arns) | The read-only roles for pull requests and the default branch, which price every change. |
| <a name="output_policy_documents"></a> [policy\_documents](#output\_policy\_documents) | The trust, boundary and workload IAM documents of the roles, for review in the plan. |
| <a name="output_protect_policy_names"></a> [protect\_policy\_names](#output\_protect\_policy\_names) | The names of the two deny-only policies on the apply roles (SecurityBaselineProtect by default); null without security\_baseline. |
| <a name="output_region_defaults"></a> [region\_defaults](#output\_region\_defaults) | IMDS token mode; the other keys are null placeholders kept for existing readers. Null without security\_baseline. |
| <a name="output_state_bucket_name"></a> [state\_bucket\_name](#output\_state\_bucket\_name) | The state bucket. |
| <a name="output_trail_arn"></a> [trail\_arn](#output\_trail\_arn) | The audit trail; null without security\_baseline. |
| <a name="output_trail_bucket_name"></a> [trail\_bucket\_name](#output\_trail\_bucket\_name) | The bucket that holds the trail's log files; null without security\_baseline. |
| <a name="output_workload_boundary_policy_arns"></a> [workload\_boundary\_policy\_arns](#output\_workload\_boundary\_policy\_arns) | The permissions boundary every workload role an apply role creates must carry, per environment. |
<!-- END_TF_DOCS -->
