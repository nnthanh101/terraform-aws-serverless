# GitHub Actions OIDC Terraform Module
> New tenants use [modules/bootstrap](../bootstrap/README.md): state, sign-in roles, guardrails and budget in one module.

> Original work by nnthanh101@gmail.com. Licensed under Apache-2.0.

## Features

- GitHub Actions OIDC provider (`token.actions.githubusercontent.com`) — one per AWS account
- **Split-trust IAM roles** (the security boundary):
  - **Plan/readonly role** — trusted from any ref (`repo:<org>/<repo>:*`); defaults to `ReadOnlyAccess`
  - **Apply role** — trusted from `main` branch ONLY (`repo:<org>/<repo>:ref:refs/heads/main`); caller-supplied least-privilege policies (no default admin)
- `create_oidc_provider = false` to reuse an existing provider (one-per-account constraint)
- Tag passthrough for cost attribution

## Basic Usage

```hcl
module "github_oidc" {
  source = "github.com/nnthanh101/terraform-aws//modules/github-oidc?ref=v0.1.0"

  github_org          = "example-org"
  github_repositories = ["b2b-commerce"]

  # Apply role must have explicit least-privilege policies — no default.
  apply_policy_arns = [
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",  # example — scope to your needs
  ]

  tags = {
    environment = "production"
    cost-centre = "platform"
  }
}
```

## Contributing

See the [`CONTRIBUTING.md`](../../CONTRIBUTING.md) file for information on how to contribute.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.11, < 2.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 6.28, < 7.0 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.apply](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.plan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.apply](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.plan](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_github_org"></a> [github\_org](#input\_github\_org) | GitHub organisation name (e.g. 'nnthanh101' or 'example-org'). Used in the IAM trust-policy sub claim. | `string` | n/a | yes |
| <a name="input_github_repositories"></a> [github\_repositories](#input\_github\_repositories) | List of repository names (without org prefix) that are granted trust. Each entry becomes sub claim 'repo:<org>/<repo>:*' for the plan role and 'repo:<org>/<repo>:ref:refs/heads/main' for the apply role. | `list(string)` | n/a | yes |
| <a name="input_apply_allowed_refs"></a> [apply\_allowed\_refs](#input\_apply\_allowed\_refs) | GitHub sub-claim ref suffixes trusted by the apply role. Defaults to main-branch push. GitHub environment: claims (e.g. 'environment:production') are valid values and preferred for protected deployments that require environment-protection reviewers — they provide an additional human-approval gate beyond branch protection. | `list(string)` | <pre>[<br/>  "ref:refs/heads/main"<br/>]</pre> | no |
| <a name="input_apply_policy_arns"></a> [apply\_policy\_arns](#input\_apply\_policy\_arns) | List of managed policy ARNs to attach to the apply role. REQUIRED when create\_roles is true (caller must supply explicit least-privilege policy ARNs; AdministratorAccess is never assumed); ignored when create\_roles is false. | `list(string)` | `[]` | no |
| <a name="input_apply_role_name"></a> [apply\_role\_name](#input\_apply\_role\_name) | Name of the IAM role assumed by apply jobs (main-branch-only trust). | `string` | `"github-actions-apply"` | no |
| <a name="input_create_oidc_provider"></a> [create\_oidc\_provider](#input\_create\_oidc\_provider) | Whether to create the aws\_iam\_openid\_connect\_provider for token.actions.githubusercontent.com. Set to false when one already exists in the account (one-per-account constraint). | `bool` | `true` | no |
| <a name="input_create_roles"></a> [create\_roles](#input\_create\_roles) | Whether to create the plan and apply roles. Set to false to create only the OIDC provider (the account's one provider, for a root that has its own pipeline roles). Default true: callers that leave it out see no change. | `bool` | `true` | no |
| <a name="input_max_session_duration"></a> [max\_session\_duration](#input\_max\_session\_duration) | Maximum session duration in seconds for both roles. | `number` | `3600` | no |
| <a name="input_plan_policy_arns"></a> [plan\_policy\_arns](#input\_plan\_policy\_arns) | List of managed policy ARNs to attach to the plan/readonly role. Defaults to ReadOnlyAccess — least-privilege for plan jobs. | `list(string)` | <pre>[<br/>  "arn:aws:iam::aws:policy/ReadOnlyAccess"<br/>]</pre> | no |
| <a name="input_plan_role_name"></a> [plan\_role\_name](#input\_plan\_role\_name) | Name of the IAM role assumed by plan/readonly jobs. | `string` | `"github-actions-plan"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A mapping of tags to assign to all resources. Keys are lower-case kebab-case. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_apply_role_arn"></a> [apply\_role\_arn](#output\_apply\_role\_arn) | ARN of the apply IAM role (trusted from main branch only). Null when create\_roles is false. |
| <a name="output_apply_role_name"></a> [apply\_role\_name](#output\_apply\_role\_name) | Name of the apply IAM role. Null when create\_roles is false. |
| <a name="output_oidc_provider_arn"></a> [oidc\_provider\_arn](#output\_oidc\_provider\_arn) | ARN of the GitHub Actions OIDC provider. |
| <a name="output_plan_role_arn"></a> [plan\_role\_arn](#output\_plan\_role\_arn) | ARN of the plan/readonly IAM role (trusted from any ref). Null when create\_roles is false. |
| <a name="output_plan_role_name"></a> [plan\_role\_name](#output\_plan\_role\_name) | Name of the plan/readonly IAM role. Null when create\_roles is false. |
<!-- END_TF_DOCS -->

## Self-Hosted GitHub Actions Runners — Architecture & Placement

### Runner Architecture Options

Three primary architectures are supported for self-hosted runners:

1. **EC2 Auto Scaling Group (ASG)** — Simplest, lowest operational overhead
   - Pros: Easy to manage, cost-effective, no Kubernetes dependency
   - Cons: Least scalable, slower warm-up, requires custom scaling logic
   - Use case: Small teams, infrequent CI runs, low burst demand

2. **Actions Runner Controller (ARC) on EKS** — Kubernetes-native, fastest scaling
   - Pros: Native Kubernetes integration, rapid pod scaling (seconds), Karpenter support for spot instances
   - Cons: Requires EKS cluster, complexity in multi-label runner group configuration
   - Note: Community ARC (Summerwind) is deprecated; use official GitHub ARC instead
   - Limitation: Official ARC runner image contains only essential packages; install additional tools via workflow actions (e.g., `actions/setup-node`) or custom runner images

3. **Philips Labs GitHub Runner** — Middle ground with EKS
   - Pros: Balanced complexity/capability, alternative to official ARC
   - Cons: Community-maintained, may have version lag

### Runner Placement Strategy

#### Recommended: Centralized Automation Account

Deploy all runners in a dedicated `automation` (or `auto`) account:
- **Isolation**: Runners separate from workload accounts, reducing cross-contamination risk
- **Centralization**: Single pane of glass for runner management, logs, and scaling policies
- **Cross-account access**: Configure IAM roles to grant runners assume-role access to workload accounts for deployment
- **Network**: Runner account VPC connected to network account via Transit Gateway for private repository access

#### Alternative: Per-Account Runners (Decentralized)

Deploy runners in each workload account:
- **Pros**: Compliance isolation, runners only access their own account
- **Cons**: Operational complexity (N clusters to manage), IP space contention, workflow routing complexity, difficult dynamic runner selection

**Trade-off summary**: Centralized (automation account) simplifies management and scales better; per-account requires more operational effort and planning.

### Security Considerations

- **Public repositories**: NEVER use self-hosted runners for public/open-source repos (exposes secrets, gives access to private resources). Use GitHub-hosted runners instead.
- **Split-trust IAM**: This module enforces split trust via `github-actions-plan` (any ref, read-only) and `github-actions-apply` (main branch only, write access). Enforce additional gates via GitHub branch protection rules and environment protection reviewers.
- **Secrets in workflows**: Use GitHub Secrets or AWS Secrets Manager integration; never hardcode credentials.
- **Audit logging**: Enable CloudTrail logging on runners' assume-role calls to track which workflows accessed which resources.

### One-Per-Account OIDC Provider Constraint

AWS supports only ONE OIDC provider per AWS account for `token.actions.githubusercontent.com`. If deploying multiple runner types (e.g., EKS cluster + ASG for fallback), reuse the same OIDC provider by setting `create_oidc_provider = false` on subsequent module invocations.



Module is maintained by [nnthanh101](https://github.com/nnthanh101).

## License

Apache 2 Licensed. See [LICENSE](../../LICENSE) for full details.
