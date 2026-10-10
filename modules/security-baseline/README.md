# security-baseline module

One AWS account's security baseline: every management API call, read and write, recorded in every Region (object reads and writes only for the buckets named in `s3_data_event_bucket_names`, none by default), the signals that matter sent to one encrypted topic that emails a person, and a deny-only policy that denies the delivery pipeline's apply roles the switch-off and tamper actions [SECURITY-BASELINE.md](SECURITY-BASELINE.md) lists. It is a deny-list on top of PowerUserAccess, so a route it does not list stays open; the owner decided on 25 Sep 2026 to keep it and deny each route an audit finds (decision 0010), and SECURITY-BASELINE.md, "Open routes (audit of 25 Sep)", says how each route that audit found was closed or accepted. Each control that adds a monthly charge is a switch, off by default.

Why each control is in or out, what it costs in ap-southeast-6 and which SOC 2 criteria it serves: [SECURITY-BASELINE.md](SECURITY-BASELINE.md). The deploy steps belong to the root that calls it.

## What it builds

- **Record** (`trail.tf`, `kms.tf`): a multi-Region trail with log file validation, into a versioned, private bucket and a log group, both kept `log_retention_days`; the bucket's own access logs in a second bucket; one customer managed key for the trail, the log group and the topic, rotated yearly. The key and the trail bucket carry `prevent_destroy`.
- **Tell** (`alerts.tf`, `alarms.tf`, `detect.tf`, `dashboard.tf`): the topic `<name_prefix>-alerts` with one email subscription, which the administrator confirms with a signed request (QUICKSTART, step 7); four CIS metric filters and their alarms, a trail-delivery alarm, and a break-glass-use alarm while BreakGlassAdmin exists; EventBridge rules for Access Analyzer findings and, with their switches, GuardDuty and Security Hub findings; the dashboard `<name_prefix>-overview`, 8 widgets. The filters count into the `SecurityBaseline` metric namespace, which SecurityBaselineProtect and the bootstrap's workload boundary deny `cloudwatch:PutMetricData` into. The alarms on a single event read the metric's maximum; the refused-calls filter has no default value and its alarm counts the matching events (SampleCount) over 5 minutes. That the SampleCount counts each refused call when several land in the same minute is not yet proved on AWS; acceptance criterion AC-7 checks it on the first apply (QUICKSTART, Show it in 10 minutes, step 5). Every filter publishes, and every alarm on one reads, unit `Count`, so a datapoint in another unit is aggregated apart. A datapoint written from elsewhere in `Count` can raise either reading, never lower it, so it can cause a false alarm but not hold a real one down (SECURITY-BASELINE.md, Known gaps).
- **Harden** (`account.tf`): the IAM password policy, S3 Block Public Access for the account, EBS encryption by default, snapshot block public access, SSM document public sharing off, an account Access Analyzer, and the default VPC's default security group emptied.
- **Switches** (`detect.tf`, `waf.tf`): GuardDuty, AWS Config, Security Hub, Inspector and a web ACL, all off by default.
- **People and protection** (`iam.tf`, `protect.tf`): BreakGlassAdmin, SecurityAuditor and DeveloperTemplate, each only when someone is named for it; SecurityBaselineProtect, a deny-only policy attached to the apply roles named.

Every name and ARN is built from `account_id`, `region` and `name_prefix`, so every policy is complete at plan time.

## Who applies it

An account administrator, from their own terminal, signed in with an administrator profile. Never the pipeline: the apply roles cannot write its state under `bootstrap/`, and the policy it attaches denies them the switch-off and tamper actions it lists on the controls it creates. A person applies it; a pull request only tests it.

## Usage

```hcl
module "baseline" {
  source = "git::https://<host>/<owner>/<repository>.git//modules/security-baseline?ref=<a 40-character commit>"

  account_id          = var.account_id
  region              = var.region
  alert_email         = var.alert_email
  ci_apply_role_names = ["gha-apply-dev", "gha-apply-production"]
}
```

The calling root sets the provider's `allowed_account_ids` and `default_tags`, and, when `break_glass_principal_arns` names anyone, supplies `break_glass_external_id` (make one with `random_uuid`).

## Choosing inputs

| Name | Default | What it sets |
|---|---|---|
| `account_id` | required | The account protected; every ARN is built from it |
| `region` | required | Home Region of the trail, log group, alarms, topic and every regional control |
| `trail_scope` | `"account"` | `account`: the trail records this account. `organization`: an organization trail, also recording every member account; run it from the management account. The trail is multi-Region in both |
| `organization_service_access_principals` | `[]` | Pass `module.organizations.service_access_principals`; `organization` scope is refused unless it holds `cloudtrail.amazonaws.com` |
| `alert_email` | required | Address the topic emails; nothing arrives until someone confirms AWS's message |
| `name_prefix` | `"security-baseline-shared"` | Prefix of every name, `<service>-shared`, at most 32 characters |
| `log_retention_days` | `400` | Days the trail files and log events are kept; 400 or more |
| `s3_data_event_bucket_names` | `[]` | Buckets whose object reads and writes the trail records; not the baseline's own |
| `access_log_bucket_enabled` | `true` | The second bucket for the trail bucket's access logs |
| `default_security_group_lockdown_enabled` | `true` | Empty the default VPC's default security group and keep it empty |
| `unauthorized_api_calls_alarm_enabled` | `true` | The alarm on 5 refused calls in 5 minutes; its metric stays when off |
| `guardduty_enabled` | `false` | GuardDuty with S3 data events and EBS malware protection |
| `config_enabled` | `false` | AWS Config, daily, into the trail bucket under `config/` |
| `security_hub_enabled` | `false` | Security Hub with Foundational Security Best Practices; needs `config_enabled` |
| `inspector_enabled` | `false` | Amazon Inspector; refused in ap-southeast-6 |
| `inspector_resource_types` | `["EC2", "ECR", "LAMBDA"]` | What Inspector scans |
| `waf_enabled` | `false` | The web ACL |
| `waf_scope` | `"REGIONAL"` | `REGIONAL`, or `CLOUDFRONT` in us-east-1 |
| `waf_rate_limit` | `2000` | Requests per client IP in 5 minutes before a block |
| `waf_resource_arns` | `[]` | Regional resources the web ACL protects; empty for `CLOUDFRONT` |
| `break_glass_principal_arns` | `[]` | IAM users, with MFA, who may assume BreakGlassAdmin; empty means no such role |
| `break_glass_external_id` | `null` (sensitive) | The external ID BreakGlassAdmin requires; required when someone is named |
| `trusted_principal_arns` | `[]` | Who may assume SecurityAuditor and DeveloperTemplate; empty means neither role exists. Identity Center roles by the pattern `arn:aws:iam::<account>:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO_<permission set>_*`, with no slash before `AWSReservedSSO`, so it matches the role path with and without the Identity Center Region |
| `developer_environments` | `["dev"]` | Environments DeveloperTemplate may read logs of and invoke |
| `production_environments` | `["production"]` | `environment` tag values DeveloperTemplate is denied |
| `ci_apply_role_names` | `[]` | Apply roles that get SecurityBaselineProtect |
| `protect_policy_prefix` | `SecurityBaseline` | Prefix of the two policy names (`<prefix>Protect`, `<prefix>ProtectWebAcl`); set another when the account already holds policies named SecurityBaselineProtect |
| `access_analyzer_enabled` | `true` | Create the account Access Analyzer; set false when the account already has one (one ACCOUNT analyzer per Region) |
| `kms_key_enabled` | `true` | One customer-managed key (about $1.00 per key version per month) for the trail files, log group and alerts topic; false encrypts the trail bucket with S3-managed keys and creates no key |
| `pipeline_role_patterns` | `["gha-*", "workload/*"]` | Roles the key, bucket and topic policies deny, whatever their own policies say |

Each input is validated at plan time; `variables.tf` states every rule and its message.

## Reading outputs

| Name | Value |
|---|---|
| `alerts_topic_arn` | The alerts topic; workload roots set it as `alarm_topic_arn` |
| `kms_key_arn` | The baseline key |
| `trail_arn` | The trail |
| `trail_bucket_name` | The bucket holding the trail files (and Config snapshots under `config/`) |
| `trail_log_group_name` | The log group the alarms read |
| `dashboard_url` | The dashboard's console address |
| `alarm_names` | Alarm key to alarm name |
| `metric_filter_patterns` | Filter key to pattern, for review and `test-metric-filter` |
| `role_arns` | People role name to ARN; empty until someone is named |
| `protect_policy_arn` | SecurityBaselineProtect (`<protect_policy_prefix>Protect`) |
| `protect_policy_names` | The two policy names, `<protect_policy_prefix>Protect` and `<protect_policy_prefix>ProtectWebAcl` |
| `waf_web_acl_arn` | The web ACL, or null when `waf_enabled` is off |
| `controls` | One boolean per control, so a review reads the choices without the tfvars |

## Tags

The module sets no tags itself: the calling root's provider `default_tags` reach every resource that takes tags (a root usually sets `environment`, `service` and `managed_by`). AWS has no tags for the account-level settings (the password policy, the account's S3 Block Public Access, EBS encryption by default, snapshot block public access, the SSM sharing setting), nor for the bucket settings, the topic policy and subscription, the key alias, metric filters, the dashboard, event targets, inline policies and policy attachments. `verify`'s `tags` line reads the trail, the trail bucket, the key, the topic, the log group and the root-usage alarm by name, each from its own service, so one that lost a tag, or is gone, fails the line.

## Tests

`tests/*.tftest.hcl` run plan-only tests against a mocked provider: no AWS account or credentials. `security-baseline.tftest.hcl` covers every control; `trail-scope.tftest.hcl` covers the account and organization trail scopes. From the repository root, in the pinned image:

```sh
task test:tier1 MODULE=security-baseline
```

`task build:validate MODULE=security-baseline` and `task build:lint MODULE=security-baseline` add the format, validate, tflint and checkov steps. Each scanner suppression in this module sits beside its reason.

## Nested module

`modules/account-guardrails` sets account-level settings for an account that does not run this baseline (the members of a tenant): the S3 public access block, the password policy and, per Region, EBS encryption, the snapshot and AMI blocks and the instance metadata defaults. This module's `account.tf` sets the same first four for its own account; the two are not called for one account with the same switches on.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28, < 7.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_accessanalyzer_analyzer.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/accessanalyzer_analyzer) | resource |
| [aws_cloudtrail.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudtrail) | resource |
| [aws_cloudwatch_dashboard.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_dashboard) | resource |
| [aws_cloudwatch_event_rule.findings](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.findings](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_cloudwatch_log_group.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_metric_filter.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_metric_filter) | resource |
| [aws_cloudwatch_metric_alarm.log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_cloudwatch_metric_alarm.trail_delivery](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm) | resource |
| [aws_config_configuration_recorder.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/config_configuration_recorder) | resource |
| [aws_config_configuration_recorder_status.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/config_configuration_recorder_status) | resource |
| [aws_config_delivery_channel.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/config_delivery_channel) | resource |
| [aws_default_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_ebs_encryption_by_default.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_encryption_by_default) | resource |
| [aws_ebs_snapshot_block_public_access.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ebs_snapshot_block_public_access) | resource |
| [aws_guardduty_detector.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_detector) | resource |
| [aws_guardduty_detector_feature.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/guardduty_detector_feature) | resource |
| [aws_iam_account_password_policy.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_account_password_policy) | resource |
| [aws_iam_policy.protect](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.protect_web_acl](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.people](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.trail_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.auditor_read_trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.developer_environments](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.trail_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.break_glass_admin](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.people](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.protect](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.protect_web_acl](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_service_linked_role.config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_service_linked_role) | resource |
| [aws_inspector2_enabler.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/inspector2_enabler) | resource |
| [aws_kms_alias.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_s3_account_public_access_block.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_account_public_access_block) | resource |
| [aws_s3_bucket.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket) | resource |
| [aws_s3_bucket_lifecycle_configuration.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_lifecycle_configuration.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration) | resource |
| [aws_s3_bucket_logging.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_logging) | resource |
| [aws_s3_bucket_ownership_controls.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_ownership_controls.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_ownership_controls) | resource |
| [aws_s3_bucket_policy.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_policy.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_policy) | resource |
| [aws_s3_bucket_public_access_block.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_public_access_block.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_server_side_encryption_configuration.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_server_side_encryption_configuration) | resource |
| [aws_s3_bucket_versioning.access_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_s3_bucket_versioning.trail](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning) | resource |
| [aws_securityhub_account.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/securityhub_account) | resource |
| [aws_securityhub_standards_subscription.foundational](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/securityhub_standards_subscription) | resource |
| [aws_sns_topic.alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic) | resource |
| [aws_sns_topic_policy.alerts](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_policy) | resource |
| [aws_sns_topic_subscription.email](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic_subscription) | resource |
| [aws_ssm_service_setting.document_public_sharing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_service_setting) | resource |
| [aws_wafv2_web_acl.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl) | resource |
| [aws_wafv2_web_acl_association.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/wafv2_web_acl_association) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_account_id"></a> [account\_id](#input\_account\_id) | The account this baseline protects. Every ARN is built from it, so policies are known at plan. | `string` | n/a | yes |
| <a name="input_alert_email"></a> [alert\_email](#input\_alert\_email) | Address that receives alarm and finding notifications. AWS sends a confirmation message first; nothing arrives until someone confirms it. | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | Home Region: the trail, log group, alarms, topic and every regional control live here. No default. | `string` | n/a | yes |
| <a name="input_access_analyzer_enabled"></a> [access\_analyzer\_enabled](#input\_access\_analyzer\_enabled) | Create the account's IAM Access Analyzer (type ACCOUNT). An account may hold only one per Region: set false when it already has one, and its findings still reach the alerts topic. | `bool` | `true` | no |
| <a name="input_access_log_bucket_enabled"></a> [access\_log\_bucket\_enabled](#input\_access\_log\_bucket\_enabled) | A second bucket that receives the trail bucket's S3 server access logs, so reads of the audit trail are themselves recorded. | `bool` | `true` | no |
| <a name="input_break_glass_external_id"></a> [break\_glass\_external\_id](#input\_break\_glass\_external\_id) | External ID that BreakGlassAdmin requires, generated by the root and kept in its state. Required when break\_glass\_principal\_arns names anyone. | `string` | `null` | no |
| <a name="input_break_glass_principal_arns"></a> [break\_glass\_principal\_arns](#input\_break\_glass\_principal\_arns) | IAM users, each signing in with MFA, who may assume BreakGlassAdmin. Empty means no break-glass role. | `list(string)` | `[]` | no |
| <a name="input_ci_apply_role_names"></a> [ci\_apply\_role\_names](#input\_ci\_apply\_role\_names) | The account's apply roles (gha-apply-<environment>) that get SecurityBaselineProtect attached. | `list(string)` | `[]` | no |
| <a name="input_config_enabled"></a> [config\_enabled](#input\_config\_enabled) | AWS Config recording in the home Region, daily, delivered to the trail bucket. | `bool` | `false` | no |
| <a name="input_default_security_group_lockdown_enabled"></a> [default\_security\_group\_lockdown\_enabled](#input\_default\_security\_group\_lockdown\_enabled) | Remove every rule from the default VPC's default security group in the home Region, and deny adding rules in that VPC to the delivery roles. | `bool` | `true` | no |
| <a name="input_developer_environments"></a> [developer\_environments](#input\_developer\_environments) | Environments whose logs and functions DeveloperTemplate may read and invoke, by the <service>-<environment>- naming rule. | `list(string)` | <pre>[<br/>  "dev"<br/>]</pre> | no |
| <a name="input_guardduty_enabled"></a> [guardduty\_enabled](#input\_guardduty\_enabled) | GuardDuty in the home Region, with S3 data events and EBS malware protection, and its high-severity findings sent to the alerts topic. | `bool` | `false` | no |
| <a name="input_inspector_enabled"></a> [inspector\_enabled](#input\_inspector\_enabled) | Amazon Inspector scanning of EC2, ECR and Lambda in the home Region. | `bool` | `false` | no |
| <a name="input_inspector_resource_types"></a> [inspector\_resource\_types](#input\_inspector\_resource\_types) | What Inspector scans when inspector\_enabled is on. | `list(string)` | <pre>[<br/>  "EC2",<br/>  "ECR",<br/>  "LAMBDA"<br/>]</pre> | no |
| <a name="input_kms_key_enabled"></a> [kms\_key\_enabled](#input\_kms\_key\_enabled) | One customer-managed key for the trail files, the trail log group and the alerts topic. False uses S3-managed encryption (SSE-S3) for the trail bucket, leaves the log group and the alerts topic on the service's default, and creates no key. | `bool` | `true` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Days the trail keeps its log files and log events. 400 covers a 12-month audit period and the fieldwork after it; 90 is for an account with no audit period. | `number` | `400` | no |
| <a name="input_name_prefix"></a> [name\_prefix](#input\_name\_prefix) | Prefix of every name this module creates, <service>-shared. At most 32 characters, so the bucket names stay within 63. | `string` | `"security-baseline-shared"` | no |
| <a name="input_organization_service_access_principals"></a> [organization\_service\_access\_principals](#input\_organization\_service\_access\_principals) | Service principals that have trusted access in the organization; pass module.organizations.service\_access\_principals. Read only when trail\_scope is organization, which is refused unless the list holds cloudtrail.amazonaws.com. | `list(string)` | `[]` | no |
| <a name="input_pipeline_role_patterns"></a> [pipeline\_role\_patterns](#input\_pipeline\_role\_patterns) | Role name patterns of the delivery pipeline and the workloads it creates: gha-* and <service\_role\_path>/* of templates/bootstrap. The key, bucket and topic policies deny them, whatever their own policies say, and trusted\_principal\_arns may not name them. | `list(string)` | <pre>[<br/>  "gha-*",<br/>  "workload/*"<br/>]</pre> | no |
| <a name="input_production_environments"></a> [production\_environments](#input\_production\_environments) | Values of the environment tag that DeveloperTemplate is denied, whatever its other rights say. | `list(string)` | <pre>[<br/>  "production"<br/>]</pre> | no |
| <a name="input_protect_policy_prefix"></a> [protect\_policy\_prefix](#input\_protect\_policy\_prefix) | Prefix of the two deny-only policy names, <prefix>Protect and <prefix>ProtectWebAcl. The default keeps SecurityBaselineProtect and SecurityBaselineProtectWebAcl; set another when the account already holds policies of those names (IAM policy names are unique per account). | `string` | `"SecurityBaseline"` | no |
| <a name="input_protected_key_tag"></a> [protected\_key\_tag](#input\_protected\_key\_tag) | Tag put on the baseline's KMS key so the organization's protect-security-logging guardrail covers it. The default is the organizations module's protected\_tag output, lz:protected = true, the one key that is not kebab-case; set the key and value your own guardrail matches, or null to leave the key untagged. | <pre>object({<br/>    key   = string<br/>    value = string<br/>  })</pre> | <pre>{<br/>  "key": "lz:protected",<br/>  "value": "true"<br/>}</pre> | no |
| <a name="input_s3_data_event_bucket_names"></a> [s3\_data\_event\_bucket\_names](#input\_s3\_data\_event\_bucket\_names) | Buckets whose object reads and writes the trail records as data events. Charged per event. | `list(string)` | `[]` | no |
| <a name="input_security_hub_enabled"></a> [security\_hub\_enabled](#input\_security\_hub\_enabled) | Security Hub in the home Region with the AWS Foundational Security Best Practices standard, and its critical and high findings sent to the alerts topic. | `bool` | `false` | no |
| <a name="input_trail_scope"></a> [trail\_scope](#input\_trail\_scope) | account: the trail records this account only. organization: an organization trail that also records every member account; run it from the management account, and set organization\_service\_access\_principals. | `string` | `"account"` | no |
| <a name="input_trusted_principal_arns"></a> [trusted\_principal\_arns](#input\_trusted\_principal\_arns) | Who may assume SecurityAuditor and DeveloperTemplate: user ARNs (each then needs an MFA sign-in within the hour), role ARNs, or role patterns such as the Identity Center roles arn:aws:iam::<account>:role/aws-reserved/sso.amazonaws.com/*AWSReservedSSO\_<set>\_*, which match with or without the Region segment in the path. Empty means neither role exists. | `list(string)` | `[]` | no |
| <a name="input_unauthorized_api_calls_alarm_enabled"></a> [unauthorized\_api\_calls\_alarm\_enabled](#input\_unauthorized\_api\_calls\_alarm\_enabled) | The alarm on refused calls (CIS, 5 within 5 minutes). Its metric and dashboard widget stay when it is off. | `bool` | `true` | no |
| <a name="input_waf_enabled"></a> [waf\_enabled](#input\_waf\_enabled) | A web ACL with the AWS common, known-bad-inputs and SQL injection rule groups and a per-IP rate limit. A fixed monthly charge per web ACL and rule, plus requests. | `bool` | `false` | no |
| <a name="input_waf_rate_limit"></a> [waf\_rate\_limit](#input\_waf\_rate\_limit) | Requests per client IP in any 5-minute window before the web ACL blocks it. | `number` | `2000` | no |
| <a name="input_waf_resource_arns"></a> [waf\_resource\_arns](#input\_waf\_resource\_arns) | Regional resources (API Gateway stages, load balancers) the web ACL protects. A CloudFront distribution names the web ACL itself, so this stays empty for CLOUDFRONT. | `list(string)` | `[]` | no |
| <a name="input_waf_scope"></a> [waf\_scope](#input\_waf\_scope) | REGIONAL for API Gateway, load balancers and similar in the home Region; CLOUDFRONT for distributions, created in us-east-1 as AWS requires. | `string` | `"REGIONAL"` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_alarm_names"></a> [alarm\_names](#output\_alarm\_names) | Alarm key to alarm name. |
| <a name="output_alerts_topic_arn"></a> [alerts\_topic\_arn](#output\_alerts\_topic\_arn) | The alerts topic. Workload roots set it as alarm\_topic\_arn, so every alarm of the account reaches the same people. |
| <a name="output_controls"></a> [controls](#output\_controls) | Which controls this account has, one boolean each, so a review reads the choices without the tfvars. |
| <a name="output_dashboard_url"></a> [dashboard\_url](#output\_dashboard\_url) | Console address of the security dashboard. |
| <a name="output_kms_key_arn"></a> [kms\_key\_arn](#output\_kms\_key\_arn) | The baseline key: trail files, the trail log group and the alerts topic. |
| <a name="output_metric_filter_patterns"></a> [metric\_filter\_patterns](#output\_metric\_filter\_patterns) | Filter key to the metric filter pattern on the trail log group, for review and for test-metric-filter. |
| <a name="output_protect_policy_arn"></a> [protect\_policy\_arn](#output\_protect\_policy\_arn) | SecurityBaselineProtect, attached to every apply role named and to DeveloperTemplate when it exists. |
| <a name="output_protect_policy_names"></a> [protect\_policy\_names](#output\_protect\_policy\_names) | The names of the two deny-only policies: <protect\_policy\_prefix>Protect and <protect\_policy\_prefix>ProtectWebAcl (the second exists only while the web ACL does). |
| <a name="output_role_arns"></a> [role\_arns](#output\_role\_arns) | People role name to ARN; empty until principals are named. |
| <a name="output_trail_arn"></a> [trail\_arn](#output\_trail\_arn) | The multi-Region trail. |
| <a name="output_trail_bucket_name"></a> [trail\_bucket\_name](#output\_trail\_bucket\_name) | Bucket that holds the trail files (and Config snapshots under config/ when Config is on). |
| <a name="output_trail_log_group_name"></a> [trail\_log\_group\_name](#output\_trail\_log\_group\_name) | Log group that receives the trail's events and feeds the alarms. |
| <a name="output_waf_web_acl_arn"></a> [waf\_web\_acl\_arn](#output\_waf\_web\_acl\_arn) | The web ACL, for a CloudFront distribution's web\_acl\_id. Null when waf\_enabled is off. |
<!-- END_TF_DOCS -->
