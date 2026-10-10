# account-guardrails

Six safe-by-default settings for one AWS account: two that apply to the whole account and four that apply in every
allowed Region. Each has its own switch. A root calls it once per account, with that account's provider. It creates
no billed resource.

## What it sets

| Setting | Switch | Scope | Value | Why it matters for a startup |
|---|---|---|---|---|
| [S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html) | `create_s3_public_access_block` | Account | All four blocks on | One wrong bucket policy cannot publish customer data. A public website uses CloudFront with origin access control instead |
| [IAM password policy](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_passwords_account-policy.html) | `create_password_policy` | Account | 14 characters or more, four character classes, last 24 reused passwords refused, no expiry | Service control policies do not reach the management account, where a break-glass user may live. No expiry follows NIST SP 800-63B 5.1.1.2, so a rarely used break-glass user does not lock itself out |
| [EBS encryption by default](https://docs.aws.amazon.com/ebs/latest/userguide/encryption-by-default.html) | `create_ebs_encryption` | Each Region | On, AWS managed `aws/ebs` key | Every new disk and snapshot is encrypted without anyone remembering to ask |
| [EBS snapshot public access block](https://docs.aws.amazon.com/ebs/latest/userguide/block-public-access-snapshots.html) | `create_snapshot_block` | Each Region | `block-all-sharing` (or `block-new-sharing`) | A disk copy, often holding a database, cannot be shared with the whole internet |
| [AMI public access block](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/block-public-access-to-amis.html) | `create_ami_block` | Each Region | `block-new-sharing` | AWS already turns this on for [new accounts](https://aws.amazon.com/about-aws/whats-new/2023/10/ami-block-public-enabled-aws-accounts-no-public-amis); the module pins it so a later switch-off shows up as drift in the next plan |
| [Instance metadata defaults](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-IMDS-new-instances.html) | `create_imds_defaults` | Each Region | IMDSv2 required, hop limit 2 | Stops the server-side request forgery path that steals instance credentials; hop limit 2 lets containers on an instance still reach IMDSv2 |

All six switches are `true` by default. `false` creates nothing for that setting and leaves whatever the account has
today; it removes exactly its own resource and no other (test `each_switch_removes_only_its_resource`), and with all
six off the plan creates nothing (test `all_off_creates_nothing`). A switch turned off after an apply is a removal:
see "Removing the module" for what each setting falls back to.

The four Region settings use the resource-level `region` argument of AWS provider 6.x
([enhanced Region support](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/guides/enhanced-region-support)),
one resource per entry in `regions`. The caller needs no provider per Region.

Each setting replaces whatever the account had before; nothing is merged. An account that already required
20-character passwords ends up requiring 14, unless `password_minimum_length` says otherwise.

**Not set, on purpose.** A customer managed EBS key costs US$1 a month per Region per account; snapshots under
`aws/ebs` cannot be shared with another account, so a workload that needs that adds its own key later. The EC2 serial
console is off by default in AWS, so pinning it adds resources and no protection.

## Cost

US$0 a month at list price. None of the six settings has a charge. EBS encryption with the AWS managed `aws/ebs` key
has no key-month fee, and its requests fall inside the 20,000 free KMS requests a month
([KMS pricing](https://aws.amazon.com/kms/pricing/), [EBS pricing](https://aws.amazon.com/ebs/pricing/)).

## Wrong account, no plan

The plan reads the account the provider signs in to and compares it with `account_id`. If a provider alias points at
the wrong account, the plan stops with `The provider signs in to <account>, not account_id: check the provider
alias.`

This check sits on the S3 Block Public Access resource, so it runs only while `create_s3_public_access_block` is
`true`. With that switch off, nothing compares the two accounts and the other five settings would land in whichever
account the provider signs in to: check the provider alias by hand, or leave the switch on.

## Usage

Call it once per account, each time with that account's provider, and pass the same Region list the root passes to
`allowed_regions` in `modules/organizations`. Every Region the `region-restriction` guardrail permits then gets the
settings. Each Region in the list must be enabled in the account: an opt-in Region that is not enabled fails the
apply.

```hcl
module "guardrails_workload" {
  source = "git::https://<host>/<owner>/<repository>.git//modules/security-baseline/modules/account-guardrails?ref=<terraform-aws-vX.Y.Z or a 40-character commit>"

  providers = { aws = aws.workload }  # signs in to the Workload account, e.g. via OrganizationAccountAccessRole

  account_id = var.workload_account_id # 12 digits, kept in a gitignored tfvars file
  regions    = var.allowed_regions     # the same list passed to module.organizations

  create_s3_public_access_block = true # also carries the wrong-account check
  create_password_policy        = true
  create_ebs_encryption         = true
  create_snapshot_block         = true
  create_ami_block              = true
  create_imds_defaults          = true
}
```

## Before you apply: IMDSv2

With `imds_v2_required = true`, new instances refuse IMDSv1 calls. Software that still uses IMDSv1 (old SDKs, old
monitoring tools, some vendor images) breaks on those instances. Existing instances keep their own setting. If an account must
run such software, set `imds_v2_required = false` for that account only; the default becomes `no-preference`.

## After apply (the owner, per account)

Settings are per account and per Region, so check each account with its own read-only profile. The management
profile would return the management account's own settings: a silent wrong answer. Run step 1 first; an expired or
wrong profile also returns empty.

| Step | `[Per-Workload]` read-only command | Expected |
|---|---|---|
| 1. Right account | `aws sts get-caller-identity --profile <account-readonly-profile>` | The account you meant to check |
| 2. EBS encryption | `aws ec2 get-ebs-encryption-by-default --region <region> --profile <account-readonly-profile>`, once per allowed Region | `"EbsEncryptionByDefault": true` |
| 3. IMDS defaults | `aws ec2 get-instance-metadata-defaults --region <region> --profile <account-readonly-profile>`, once per allowed Region | `"HttpTokens": "required"` |

For each account, the number of `true` answers in step 2 and of `required` answers in step 3 equals the number of
allowed Regions. A `false`, a `0` or an empty answer is checked again from the management account through the
account-access role (`OrganizationAccountAccessRole`) before anyone calls it a failure: the read-only profile may lack
the permission rather than the account lack the setting.

## Removing the module

Removing the module (or running `terraform destroy`) does not restore what the account had before:

| Setting | After removal |
|---|---|
| S3 Block Public Access | Removed from the account: buckets fall back to their own bucket-level settings |
| IAM password policy | Removed: the account has no password policy |
| EBS encryption by default | Turned off in each Region |
| EBS snapshot public access block | Turned off in each Region |
| Instance metadata defaults | Back to `no-preference` in each Region |
| AMI public access block | Stays on in AWS; Terraform only stops tracking it |

To stop managing the account with Terraform but keep every setting in place, replace the module block with a
`removed` block (Terraform 1.7 or later) and apply:

```hcl
removed {
  from = module.guardrails_workload

  lifecycle {
    destroy = false
  }
}
```

## Inputs

| Name | Default | Purpose |
|---|---|---|
| `account_id` | required | The 12-digit account the settings apply to; the plan fails if the provider signs in elsewhere, while `create_s3_public_access_block` is `true` |
| `regions` | required | Regions that get the four per-Region settings; at least one, no repeats, each like `ap-southeast-2`; pass `allowed_regions` |
| `create_s3_public_access_block` | `true` | Create the account-level S3 public access block |
| `create_password_policy` | `true` | Create the IAM account password policy |
| `create_ebs_encryption` | `true` | Turn on EBS encryption by default in each Region |
| `create_snapshot_block` | `true` | Block public sharing of EBS snapshots in each Region |
| `create_ami_block` | `true` | Block new public sharing of AMIs in each Region |
| `create_imds_defaults` | `true` | Set the instance metadata defaults in each Region |
| `password_minimum_length` | `14` | Minimum IAM password length, 14 to 128 |
| `snapshot_block_public_access` | `block-all-sharing` | `block-all-sharing` or `block-new-sharing`; `unblocked` is refused |
| `imds_v2_required` | `true` | `true` requires IMDSv2 for new instances; `false` sets `no-preference` |
| `imds_hop_limit` | `2` | Default metadata hop limit, 1 to 64 |

## Outputs

| Name | Value |
|---|---|
| `account_id` | The account the guardrails apply to |
| `regions` | The Regions that carry the per-Region settings, sorted |
| `settings` | Per Region: `ebs_encryption`, `snapshot_bpa`, `ami_bpa`, `imds_tokens`; a value is `null` when its switch is off |

## Tests

`terraform test` plans against a mocked AWS provider, with no credentials and no apply. There are 21 runs:
`grep -cE '^ *run "' tests/guardrails.tftest.hcl` prints `21`. Thirteen check the settings: the four S3 blocks, the
password policy, one resource per Region with `region` equal to its key, encryption, both snapshot states, the AMI
block, the IMDS default and `imds_v2_required = false`, every switch off, one switch removing only its own resource,
and the `settings` output. Eight check a refusal each (`grep -c expect_failures tests/guardrails.tftest.hcl` prints
`8`): a provider in the wrong account, a malformed account ID, an empty, repeated or malformed Region list, a
password length under 14, an `unblocked` snapshot state and a hop limit over 64.

```bash
task build:validate MODULE=security-baseline/modules/account-guardrails
task test:tier1 MODULE=security-baseline/modules/account-guardrails
```
