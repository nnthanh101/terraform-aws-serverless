# Bootstrap Terraform Module

> Derived from the bootstrap template of the terraform-aws plugin (Apache-2.0). See [NOTICE.txt](NOTICE.txt).

One module per tenant for CI-only delivery on AWS: the state bucket and its key, GitHub or Azure DevOps sign-in roles, guardrails and a budget. An account administrator applies it once per account, or once per tenant in a shared account. Afterwards only approved CI runs change infrastructure there.

## What it creates

- **State bucket.** It holds Terraform state and saved plans. It is versioned, encrypted with its own key, and closed to the public, to plain HTTP and to TLS below 1.2. Saved plans under `plans/` expire after `plans_expiration_days` (7); replaced state versions after `noncurrent_version_expiration_days` (90). No GitHub role or workload role may change a bucket setting; only the account administrator does, through this module. The default name is `<account_id>-tfstate-<region>`, the tenant convention.
- **State key.** A customer managed key with rotation. The plan and apply roles use it only through S3 in this Region, and the apply roles cannot change it or create grants on it.
- **Upload rule.** The bucket accepts only uploads encrypted with the state key. Every backend therefore sets `kms_key_id` to the key ARN from `state_kms_key_arn`; an alias, a key ID or SSE-S3 is refused.
- **No key, no cost.** `create_state_kms_key = false` skips the key and its alias (about 1 USD a month): the bucket then uses its default SSE-S3 (AES-256), the key statements drop out of the bucket and role policies, and `state_kms_key_arn` and `backend_settings.kms_key_id` are `null`. State is still encrypted at rest and reachable only over TLS 1.2 or later; you give up your own key policy and the per-use audit trail. The default, `true`, changes nothing for an existing bootstrap.
- **GitHub sign-in.** The account's OIDC provider (`create_oidc_provider`, on by default) and one role per job type. Every role trusts exact subjects with `StringEquals`, one per entry of `github_repositories`, never a wildcard.

  | Role (default `name_prefix = "gha"`) | Used by | What it can do |
  | --- | --- | --- |
  | `gha-plan-pr` | pull requests | Plan dev. It writes nothing, and cannot read production state, saved plans, application data, log events, API keys, secrets or tokens. |
  | `gha-plan-default` | the default branch, after merge | Plan production and save that plan for release. Same data-plane denies. |
  | `gha-apply-<env>` | the GitHub Environment `<env>` | Apply to that environment. In one account, every environment outside `production_environments` is denied every production resource. |

  Optional claims tighten the trust further. `github_repository_ids` and `github_owner_id` add `repository_id` and `repository_owner_id`, which do not change when a repository or owner is renamed. `apply_workflow_refs` limits an environment's apply role to the listed workflows through `job_workflow_ref`. `github_subject_prefixes` takes the subject prefix GitHub reports for each repository (`gh api repos/<organisation>/<repository>/actions/oidc/customization/sub --jq .sub_claim_prefix`): a repository created after 2026-07-15 signs in as `repo:<organisation>@<id>/<repository>@<id>:...`, which a name-based subject never matches.
- **Apply guardrails.** Apply roles carry `apply_policy_arns` (default PowerUserAccess) plus inline denies: FoundationProtect (delivery roles, OIDC provider, boundaries, state bucket settings, bootstrap state, state key, budget), ProductionDeny in one account, and workload IAM limited to `/<service_role_path>/<env>/`.
- **One workload boundary per environment.** Every role the pipeline creates must carry its own environment's boundary. In one account the dev boundary also denies every production resource.
- **Monthly budget.** It emails the budget owner at 80% and 100% of actual cost, and when the forecast passes 100%. Credits are left out, so spend a credit pays for still alerts.
- **Break-glass, in a management account.** Break-glass for the management account is the root user with MFA (several FIDO2 keys); see AWS docs: [the AWS emergency access guide](https://docs.aws.amazon.com/singlesignon/latest/userguide/emergency-access.html) and [root user MFA](https://docs.aws.amazon.com/IAM/latest/UserGuide/enable-mfa-for-root.html).
- **Guardrail for the automation identity.** The output `automation_guardrail_policy_json` denies writes, secrets, application data, API key values and token calls.
- **API Gateway logging role**, once per account and Region (`enable_api_gateway_account`). REST API stages cannot write logs without it.

The module has no provider block. The caller's provider sets the account, Region and default tags; the plan stops when its credentials belong to another account than `account_id` or it points at another Region than `region`.

## Basic Usage

```hcl
module "bootstrap" {
  source = "../../modules/bootstrap"

  account_id          = "123456789012"
  region              = "ap-southeast-2"
  github_repositories = ["the terraform-aws plugin repository"]
  default_branch      = "develop"
  budget_limit_usd    = 100
  notification_email  = "finance@example.com"
}
```

Complete roots with the provider, variables and backend:

| Example | The account it bootstraps |
|---|---|
| [single-account](examples/single-account) | One account for dev and production, with no organization |
| [management-account](examples/management-account) | An organization's management account: no pipeline role |
| [member-account](examples/member-account) | A member account that runs workloads, one tfvars file per kind: dev and production in one account, a sandbox with no production role, and a card-data account that only its release workflow applies to |

## Azure DevOps

`ci_platform = "azure-devops"` swaps the GitHub sign-in for Azure DevOps service connections; the state bucket, key, boundaries, guardrails, production denies, budget and ECR are the same. The default, `"github"`, changes nothing for an existing caller.

- The OIDC provider is `https://vstoken.dev.azure.com/<ado_organization_id>` with client id `api://AzureADTokenExchange`; no GitHub provider is created. `create_oidc_provider = false` reuses an existing one, passed as `oidc_provider_arn`.
- Both plan roles trust the subjects of `ado_plan_service_connections`, each `sc://<ado_organization_name>/<project>/<name>`. Each `<prefix>-apply-<env>` role trusts only the subjects of `ado_apply_service_connections[<env>]`, so every entry of `environments` needs one.
- Every trust is `StringEquals` on `<issuer>:aud` and `<issuer>:sub`, never `StringLike`. A project or name with `*`, `?`, `$` or `/` is refused, and so is a key of `ado_apply_service_connections` that is not in `environments`.
- A service connection may appear in only one place: the plan list or one environment's apply list, compared without regard to case. Trust is by service connection name, because IAM can pin only `aud` and `sub` for this issuer. Limit who can administer service connections, above all the production apply connection: anyone who can create or rename a connection to a trusted name can sign in as that role.
- `github_repositories` and the other `github_*` inputs are not used, and are refused with `azure-devops`: `github_repositories`, `github_repository_ids`, `github_subject_prefixes`, `github_owner_id`, `github_owner_ids` and `apply_workflow_refs`. The `ado_*` inputs are refused with `ci_platform = "github"`.

```hcl
module "bootstrap" {
  source = "../../modules/bootstrap"

  account_id         = "123456789012"
  region             = var.region
  budget_limit_usd   = 250
  notification_email = "finance@example.com"

  ci_platform           = "azure-devops"
  ado_organization_id   = "11111111-1111-1111-1111-111111111111"
  ado_organization_name = "acme"

  ado_plan_service_connections = [{ project = "platform", name = "aws-plan" }]
  ado_apply_service_connections = {
    dev        = [{ project = "platform", name = "aws-apply-dev" }]
    production = [{ project = "platform", name = "aws-apply-prod" }]
  }
}
```

## One account or one account per environment

`account_mode = "single"` (default): one account holds every environment. `production_environments` names the production ones; the default is `["production"]`, the name the delivery workflows use. The plan refuses a list that is empty or names an environment outside `environments`. Every other environment's apply role and boundary are denied production resources:

- by the `environment` tag, whose value is the production environment's name;
- by name, `<service>-<environment>-<purpose>`;
- by state key, `<service>/<environment>/terraform.tfstate`, and saved plans.

Resources must therefore follow these naming and tagging rules, and state keys must carry the environment. Two CloudFront settings carry neither a tag nor a name, origin access controls and response headers policies, so no non-production apply role may change them.

`account_mode = "landing-zone"`: one account per environment. Call the module once per account, each with its own provider alias, and set `production_environments = []` in accounts without production:

```hcl
module "bootstrap_dev" {
  source    = "../../modules/bootstrap"
  providers = { aws = aws.dev }

  account_id              = "111111111111"
  account_mode            = "landing-zone"
  environments            = ["dev"]
  production_environments = []
  # region, github_repositories, default_branch, budget_limit_usd, notification_email as above
}
```

A management account applied by a person uses `ci_roles = false`: it gets its state bucket, key and budget, and no OIDC provider, plan or apply role, or workload boundary.

## Several tenants in one account

Each tenant is its own module call with:

- its own `name_prefix`, for example `gha` for the first and `billing` for the second. With any prefix other than `gha`, the prefix also goes in front of the boundary, key alias, budget, logging role and default bucket names (`<account_id>-billing-tfstate-<region>`). Prefixes have no hyphen, so one tenant's `role/<prefix>-*` pattern never matches another tenant's roles;
- its own `service_role_path`, for example `workload-billing`. Apply roles create and pass workload roles only under their own path;
- `create_oidc_provider = false` and `oidc_provider_arn` set to the first tenant's `oidc_provider_arn` output, because an account holds one GitHub provider;
- `enable_api_gateway_account = false`, because an account and Region hold one API Gateway logging setting.

What this does not separate: tenants in one account share the account boundary. An apply role with PowerUserAccess can reach the other tenant's resources and, through S3, its state. Where tenants must not reach each other, give each tenant its own account.

## Trust of workload roles

An apply role creates roles, and changes their trust, only under `/<service_role_path>/<its environment>/` and only with its own environment's boundary. Anywhere else it is explicitly denied `iam:CreateRole` and `iam:UpdateAssumeRolePolicy`.

IAM has no condition key on what a trust policy says, so no policy here stops a pipeline run from writing a trust that names an outside account on a role inside its own path. Two controls cover this: the approver reads every `aws_iam_role` trust change in the saved plan, and the organisation administrator can add a resource control policy that denies `sts:AssumeRole` on workload roles to callers outside the organisation:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Sid": "WorkloadRolesOnlyFromTheOrganisation",
    "Effect": "Deny",
    "Principal": "*",
    "Action": "sts:AssumeRole",
    "Resource": "arn:aws:iam::*:role/workload/*",
    "Condition": {
      "StringNotEqualsIfExists": { "aws:PrincipalOrgID": "<organisation id>" },
      "BoolIfExists": { "aws:PrincipalIsAWSService": "false" }
    }
  }]
}
```

## Apply it

An account administrator applies it from their own terminal with an administrator profile, first with a local backend:

```sh
# In a copy of examples/single-account, or the tenant root that calls the module:
cp terraform.tfvars.example terraform.tfvars   # fill every value; read the default branch from the repository settings
terraform init && terraform apply
```

Then copy `backend.tf.example` to `backend.tf`, fill it from the `backend_settings` output, and move the state into the new bucket with `terraform init -migrate-state`. Apply roles cannot write under `bootstrap/`, so this state changes only through the administrator.

After the apply:

1. Copy the role ARNs, bucket name and Region into the repository and Environment variables that the CI workflows read.
2. Copy `backend_settings` into every workload root's backend, with a key of `<service>/<env>/terraform.tfstate`, and each environment's entry of `workload_boundary_policy_arns` into that root.
3. Attach `automation_guardrail_policy_json` to the automation's read-only permission sets.

## From the plugin template

A root built from the terraform-aws plugin's template keeps its resources by moving them into the module. Every resource keeps its address under `module.bootstrap`, except two:

```hcl
moved {
  from = aws_kms_key.state # and likewise for every other resource of the template
  to   = module.bootstrap.aws_kms_key.state
}

moved {
  from = aws_iam_openid_connect_provider.github
  to   = module.bootstrap.aws_iam_openid_connect_provider.github[0]
}

moved {
  from = aws_iam_role_policy_attachment.apply_power_user["dev"] # and ["production"]
  to   = module.bootstrap.aws_iam_role_policy_attachment.apply_policies["dev|arn:aws:iam::aws:policy/PowerUserAccess"]
}
```

Replace `github_org` and `github_repo` with `github_repositories = ["<org>/<repo>"]`, and keep `state_bucket_name` set to the existing bucket.

## Checks

`terraform test` runs plan-only checks against a mocked provider, with no AWS credentials: ported from the template (`tests/bootstrap.tftest.hcl`), for Azure DevOps and the unchanged github default (`tests/azure-devops.tftest.hcl`), for the reuse inputs (`tests/tenants.tftest.hcl`), and through the examples (`tests/example.tftest.hcl`, `tests/management-account.tftest.hcl`, `tests/member-account.tftest.hcl`). `terraform test` prints the current count.

## Provenance

Derived from `plugins/terraform-aws/templates/bootstrap` in the terraform-aws plugin repository (commit efe91f7), Apache-2.0, same author. Features ported from `modules/genesis`, `modules/github-oidc` and `modules/ado-oidc`. Details and the list of changes are in [NOTICE.txt](NOTICE.txt) (ADR-029).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28, < 7.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_account_alternate_contact.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/account_alternate_contact) | resource |
| [aws_api_gateway_account.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/api_gateway_account) | resource |
| [aws_budgets_budget.account](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/budgets_budget) | resource |
| [aws_ecr_lifecycle_policy.container](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy) | resource |
| [aws_ecr_repository.container](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository) | resource |
| [aws_ecr_repository_policy.container](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository_policy) | resource |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_policy.workload_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.api_gateway_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.apply](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.plan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.apply_foundation_protect](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.apply_production_deny](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.apply_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.apply_workload_iam](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.plan_data_plane_deny](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.plan_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.api_gateway_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.apply_policies](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.plan_read_only](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_user.break_glass](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user) | resource |
| [aws_iam_user_policy.break_glass_require_mfa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user_policy) | resource |
| [aws_iam_user_policy_attachment.break_glass_admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_user_policy_attachment) | resource |
| [aws_kms_alias.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_bucket.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_ownership_controls.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_account_id"></a> [account\_id](#input\_account\_id) | The 12-digit AWS account this bootstrap belongs to. The plan stops when the caller's credentials are for any other account. | `string` | n/a | yes |
| <a name="input_budget_limit_usd"></a> [budget\_limit\_usd](#input\_budget\_limit\_usd) | Monthly cost budget for this account in US dollars. Notifications go out at 80% and 100% of actual cost, and when the forecast passes 100%. | `number` | n/a | yes |
| <a name="input_default_branch"></a> [default\_branch](#input\_default\_branch) | The repositories' default branch, read from the repository settings. Only the plan-default role trusts it. | `string` | n/a | yes |
| <a name="input_notification_email"></a> [notification\_email](#input\_notification\_email) | Email address of the budget owner who receives the budget notifications. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS Region for the state bucket, key and roles. There is no default; set it per deployment. The plan stops when the provider is set to another Region. | `string` | n/a | yes |
| <a name="input_abort_incomplete_multipart_upload_days"></a> [abort\_incomplete\_multipart\_upload\_days](#input\_abort\_incomplete\_multipart\_upload\_days) | Days after which an incomplete multipart upload under the state-history rule (the whole bucket) is aborted. The plans/ rule always aborts after 1 day. | `number` | `1` | no |
| <a name="input_account_mode"></a> [account\_mode](#input\_account\_mode) | single: one account holds every environment, so every environment outside production\_environments is denied production resources. landing-zone: one account per environment. | `string` | `"single"` | no |
| <a name="input_ado_apply_service_connections"></a> [ado\_apply\_service\_connections](#input\_ado\_apply\_service\_connections) | Per environment, the service connections its apply role trusts, each { project, name }. Every entry of environments needs at least one with ci\_platform = azure-devops and ci\_roles = true; keys must be entries of environments; refused with github. | <pre>map(list(object({<br/>    project = string<br/>    name    = string<br/>  })))</pre> | `{}` | no |
| <a name="input_ado_organization_id"></a> [ado\_organization\_id](#input\_ado\_organization\_id) | Azure DevOps organization GUID (lower-case); part of the token issuer https://vstoken.dev.azure.com/<GUID>. Required with ci\_platform = azure-devops and ci\_roles = true; refused with github. | `string` | `null` | no |
| <a name="input_ado_organization_name"></a> [ado\_organization\_name](#input\_ado\_organization\_name) | Azure DevOps organization name, the first segment of the subject sc://<organization>/<project>/<connection>. No wildcard characters. Required with ci\_platform = azure-devops and ci\_roles = true; refused with github. | `string` | `null` | no |
| <a name="input_ado_plan_service_connections"></a> [ado\_plan\_service\_connections](#input\_ado\_plan\_service\_connections) | Service connections the two plan roles trust, each { project, name }. Exact names only; at least one with ci\_platform = azure-devops and ci\_roles = true; refused with github. | <pre>list(object({<br/>    project = string<br/>    name    = string<br/>  }))</pre> | `[]` | no |
| <a name="input_alternate_contacts"></a> [alternate\_contacts](#input\_alternate\_contacts) | The account's alternate contacts, keyed by billing, operations or security. | <pre>map(object({<br/>    name  = string<br/>    title = string<br/>    email = string<br/>    phone = string<br/>  }))</pre> | `{}` | no |
| <a name="input_apply_policy_arns"></a> [apply\_policy\_arns](#input\_apply\_policy\_arns) | Managed policies attached to every apply role. Null attaches PowerUserAccess. The inline denies apply either way. | `list(string)` | `null` | no |
| <a name="input_apply_workflow_refs"></a> [apply\_workflow\_refs](#input\_apply\_workflow\_refs) | Per environment, the workflows allowed to use its apply role, as <organisation>/<repository>/.github/workflows/<file>@<ref>. An environment listed here also requires the job\_workflow\_ref claim; environments not listed do not. | `map(list(string))` | `{}` | no |
| <a name="input_break_glass_path"></a> [break\_glass\_path](#input\_break\_glass\_path) | IAM path of the break-glass user. A user created in the console has the path /; keep it when importing so the import changes nothing. | `string` | `"/break-glass/"` | no |
| <a name="input_break_glass_user"></a> [break\_glass\_user](#input\_break\_glass\_user) | Create the break-glass IAM user (administrator, no access key, MFA required) in an organization's management account. The owner adds its password and MFA in the console after the apply; Terraform never holds either. A user the owner already made in the console is adopted with import blocks in the calling root, to aws\_iam\_user.break\_glass[0], aws\_iam\_user\_policy\_attachment.break\_glass\_admin[0] and aws\_iam\_user\_policy.break\_glass\_require\_mfa[0]. | `bool` | `false` | no |
| <a name="input_change_id"></a> [change\_id](#input\_change\_id) | Four-digit change record number that this apply belongs to, written to the change tag. Leave null for no change tag. | `string` | `null` | no |
| <a name="input_ci_platform"></a> [ci\_platform](#input\_ci\_platform) | The pipeline platform the roles trust: github (GitHub Actions, the default) or azure-devops (Azure DevOps service connections). Everything else the module builds is the same for both. | `string` | `"github"` | no |
| <a name="input_ci_roles"></a> [ci\_roles](#input\_ci\_roles) | Create the OIDC trust (GitHub or Azure DevOps, per ci\_platform) and the plan and apply roles. Turn it off in an organization's management account: a person applies the landing zone there, so the account needs its state bucket, key and budget only. | `bool` | `true` | no |
| <a name="input_container_repositories"></a> [container\_repositories](#input\_container\_repositories) | Names of container image registries (ECR) for apps shipped as Lambda container images: immutable tags, scan on push, AES256, untagged images expire beyond the newest 20, Lambda in this account may pull. Empty creates none. | `list(string)` | `[]` | no |
| <a name="input_create_oidc_provider"></a> [create\_oidc\_provider](#input\_create\_oidc\_provider) | Create the account's OIDC provider for the ci\_platform issuer (GitHub or Azure DevOps). An account holds only one; a second tenant in the same account sets false and passes oidc\_provider\_arn. Ignored with ci\_roles = false. | `bool` | `true` | no |
| <a name="input_create_state_kms_key"></a> [create\_state\_kms\_key](#input\_create\_state\_kms\_key) | true (the default) encrypts state and saved plans with a customer-managed key, about 1 USD a month: its policy is yours, every use is in CloudTrail, and the bucket policy refuses any other key. false uses the bucket default SSE-S3 (AES-256): no key, no cost, still encrypted at rest and reachable only over TLS 1.2 or later; backend\_settings.kms\_key\_id is then null. | `bool` | `true` | no |
| <a name="input_enable_api_gateway_account"></a> [enable\_api\_gateway\_account](#input\_enable\_api\_gateway\_account) | Sets the account's API Gateway logging role in this Region. REST API stages cannot write access or execution logs without it. Set false when another stack in this account and Region already manages the setting, such as a second tenant's bootstrap. | `bool` | `true` | no |
| <a name="input_environments"></a> [environments](#input\_environments) | Environments deployed into this account. Each gets an apply role that trusts only its GitHub Environment. Names follow the workload roots: 2 to 12 lower-case letters or digits, starting with a letter. | `list(string)` | <pre>[<br/>  "dev",<br/>  "production"<br/>]</pre> | no |
| <a name="input_github_owner_id"></a> [github\_owner\_id](#input\_github\_owner\_id) | Numeric GitHub ID of the organisation or user that owns the repositories. When set, every role also requires the repository\_owner\_id claim. | `string` | `null` | no |
| <a name="input_github_owner_ids"></a> [github\_owner\_ids](#input\_github\_owner\_ids) | Numeric GitHub owner IDs of github\_repositories, in the same order, for repositories held by more than one organisation. When set, the repository\_owner\_id claim lists the distinct IDs. Do not set together with github\_owner\_id. | `list(string)` | `[]` | no |
| <a name="input_github_repositories"></a> [github\_repositories](#input\_github\_repositories) | Repositories the GitHub roles trust, each as <organisation>/<repository>. Every role trusts the exact subject of each one. Required with ci\_platform = github; not used with azure-devops. | `list(string)` | `[]` | no |
| <a name="input_github_repository_ids"></a> [github\_repository\_ids](#input\_github\_repository\_ids) | Numeric GitHub IDs of github\_repositories, in the same order. When set, every role also requires the repository\_id claim; names can be reused, IDs cannot. | `list(string)` | `[]` | no |
| <a name="input_github_subject_prefixes"></a> [github\_subject\_prefixes](#input\_github\_subject\_prefixes) | The OIDC subject prefix GitHub reports for each of github\_repositories, in the same order: `gh api repos/<organisation>/<repository>/actions/oidc/customization/sub --jq .sub_claim_prefix`. Repositories created after 2026-07-15 use the immutable form repo:<organisation>@<id>/<repository>@<id>; empty means repo:<organisation>/<repository> for every repository. | `list(string)` | `[]` | no |
| <a name="input_max_session_duration"></a> [max\_session\_duration](#input\_max\_session\_duration) | Maximum session length in seconds for every role this module creates. | `number` | `3600` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix of the delivery role names (<prefix>-plan-pr, <prefix>-plan-default, <prefix>-apply-<environment>). Any value other than gha is also put in front of the boundary, key alias, budget, logging role and default bucket names. Each tenant in one account needs its own. | `string` | `"gha"` | no |
| <a name="input_noncurrent_version_expiration_days"></a> [noncurrent\_version\_expiration\_days](#input\_noncurrent\_version\_expiration\_days) | Days that replaced state versions are kept before they expire. | `number` | `90` | no |
| <a name="input_oidc_provider_arn"></a> [oidc\_provider\_arn](#input\_oidc\_provider\_arn) | ARN of the account's existing OIDC provider for the ci\_platform issuer. Required when create\_oidc\_provider = false, and refused otherwise. Ignored with ci\_roles = false. | `string` | `null` | no |
| <a name="input_passrole_services"></a> [passrole\_services](#input\_passrole\_services) | Extra service principals (for example bedrock-agentcore.amazonaws.com) the apply roles may pass workload roles to, besides Lambda and Step Functions. | `list(string)` | `[]` | no |
| <a name="input_plans_expiration_days"></a> [plans\_expiration\_days](#input\_plans\_expiration\_days) | Days that saved plans under plans/ are kept. They hold sensitive values; keep this as short as release approval allows. | `number` | `7` | no |
| <a name="input_production_environments"></a> [production\_environments](#input\_production\_environments) | The entries of environments that are production. In single-account mode every other environment's apply role and workload boundary are denied their resources (by tag and by name), their state and the saved plans. Only their apply roles read saved plans. The delivery workflows use the name production. | `list(string)` | <pre>[<br/>  "production"<br/>]</pre> | no |
| <a name="input_protect_security_baseline"></a> [protect\_security\_baseline](#input\_protect\_security\_baseline) | Add the security baseline deny statements to every workload boundary: its alerts topic and rules, trail log group, account-level logs policies, the account S3 public access block and the SecurityBaseline metric namespace stay as the person who applied the baseline left them. false leaves them out. | `bool` | `true` | no |
| <a name="input_security_baseline_prefix"></a> [security\_baseline\_prefix](#input\_security\_baseline\_prefix) | name\_prefix the security baseline was applied with; its topic, rules and log groups are named <prefix>-*. Used only with protect\_security\_baseline = true. | `string` | `"security-baseline"` | no |
| <a name="input_service"></a> [service](#input\_service) | Short name used as the first part of resource names ('<service>-<environment>-<purpose>') and as the service tag. | `string` | `"platform"` | no |
| <a name="input_service_role_path"></a> [service\_role\_path](#input\_service\_role\_path) | IAM path under which apply roles may create workload roles, as /<path>/<environment>/. Each tenant in one account needs its own. | `string` | `"workload"` | no |
| <a name="input_state_bucket_name"></a> [state\_bucket\_name](#input\_state\_bucket\_name) | Name of the S3 bucket that holds Terraform state and saved plans. Null uses <account\_id>-tfstate-<region>, the tenant convention, with <name\_prefix>- before tfstate when name\_prefix is not gha. | `string` | `null` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags for every resource that takes tags, for example module.tags.common\_tags. Keys are lower-case kebab-case. The module adds environment = shared, service, managed-by and change unless a key here already has the same name. | `map(string)` | `{}` | no |
| <a name="input_workload_boundary_extra_actions"></a> [workload\_boundary\_extra\_actions](#input\_workload\_boundary\_extra\_actions) | Per environment, extra read actions (no wildcard; no iam, sts or organizations) added to that environment's workload boundary. | `map(list(string))` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_apply_role_arns"></a> [apply\_role\_arns](#output\_apply\_role\_arns) | One apply role per environment, for the variables APPLY\_ROLE\_ARN\_<ENV>. Empty with ci\_roles = false. |
| <a name="output_apply_role_names"></a> [apply\_role\_names](#output\_apply\_role\_names) | One apply role name per environment. The names are known at plan, so a caller that passes them on (for example to the security baseline's ci\_apply\_role\_names) waits for the roles without a module-level depends\_on. Empty with ci\_roles = false. |
| <a name="output_automation_guardrail_policy_json"></a> [automation\_guardrail\_policy\_json](#output\_automation\_guardrail\_policy\_json) | Inline policy for the automation's read-only permission sets: denies writes, secrets, data-plane reads, API key values, token calls and non-read calls made through the AWS MCP service. |
| <a name="output_backend_settings"></a> [backend\_settings](#output\_backend\_settings) | Values for envs/<env>.backend.hcl in each workload root (add key = "<service>/<env>/terraform.tfstate"). |
| <a name="output_break_glass_user_arn"></a> [break\_glass\_user\_arn](#output\_break\_glass\_user\_arn) | The break-glass user's ARN, or null when break\_glass\_user is false. Its password and MFA are set in the console. |
| <a name="output_budget_name"></a> [budget\_name](#output\_budget\_name) | Monthly account budget that notifies the budget owner at 80% and 100% of actual cost, and when the forecast passes 100%. |
| <a name="output_container_repository_arns"></a> [container\_repository\_arns](#output\_container\_repository\_arns) | Repository ARN per container\_repositories name. Empty when none are listed. |
| <a name="output_container_repository_urls"></a> [container\_repository\_urls](#output\_container\_repository\_urls) | Repository URL per container\_repositories name. Empty when none are listed. |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | OIDC provider the roles trust (GitHub Actions, or Azure DevOps with ci\_platform = azure-devops): the one this module created, or oidc\_provider\_arn when create\_oidc\_provider = false. Null with ci\_roles = false. |
| <a name="output_plan_role_arns"></a> [plan\_role\_arns](#output\_plan\_role\_arns) | Repository variables PLAN\_PR\_ROLE\_ARN and PLAN\_DEFAULT\_ROLE\_ARN. Empty with ci\_roles = false. |
| <a name="output_plan_role_names"></a> [plan\_role\_names](#output\_plan\_role\_names) | Read-only plan roles, for the trust check's --plan-roles. <prefix>-plan-pr plans pull requests and cannot read production state; <prefix>-plan-default plans production after merge and saves the plan. Empty with ci\_roles = false. |
| <a name="output_policy_documents"></a> [policy\_documents](#output\_policy\_documents) | The documents a reviewer reads in the plan, by name: the trust of each GitHub role, the workload boundary and the workload IAM policy of each environment. Empty with ci\_roles = false. |
| <a name="output_state_bucket_arn"></a> [state\_bucket\_arn](#output\_state\_bucket\_arn) | ARN of the state bucket. |
| <a name="output_state_bucket_name"></a> [state\_bucket\_name](#output\_state\_bucket\_name) | S3 bucket for Terraform state (keys <service>/<environment>/terraform.tfstate) and saved plans (plans/<run\_id>/). |
| <a name="output_state_bucket_region"></a> [state\_bucket\_region](#output\_state\_bucket\_region) | AWS Region the state bucket resides in. |
| <a name="output_state_kms_key_arn"></a> [state\_kms\_key\_arn](#output\_state\_kms\_key\_arn) | Customer managed key for state and saved plans; null when create\_state\_kms\_key is false. Put it in each backend.hcl as kms\_key\_id when it is set. |
| <a name="output_workload_boundary_policy_arns"></a> [workload\_boundary\_policy\_arns](#output\_workload\_boundary\_policy\_arns) | Permissions boundary per environment. Each workload root sets permissions\_boundary\_arn to its own environment's entry. Empty with ci\_roles = false. |
| <a name="output_workload_role_paths"></a> [workload\_role\_paths](#output\_workload\_role\_paths) | IAM path per environment under which apply roles may create and pass workload roles. Empty with ci\_roles = false. |
<!-- END_TF_DOCS -->
