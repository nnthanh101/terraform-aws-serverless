# Copyright 2026 Nhat-Thanh Nguyen (nnthanh101@gmail.com). Licensed under Apache-2.0. See LICENSE.
# Plan-only tests: several GitHub owners, extra read actions in a workload boundary, extra PassRole services and container registries.
mock_provider "aws" {
  override_data {
    target = data.aws_partition.current
    values = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  override_data {
    target = data.aws_caller_identity.current
    values = {
      account_id = "123456789012"
    }
  }

  override_data {
    target = data.aws_region.current
    values = {
      region = "ap-southeast-2"
    }
  }

  override_resource {
    target          = aws_kms_key.state
    override_during = plan
    values = {
      arn    = "arn:aws:kms:ap-southeast-2:123456789012:key/00000000-0000-0000-0000-000000000000"
      key_id = "00000000-0000-0000-0000-000000000000"
    }
  }
}

variables {
  account_id          = "123456789012"
  region              = "ap-southeast-2"
  github_repositories = ["acme/platform", "other/app"]
  default_branch      = "develop"
  budget_limit_usd    = 250
  notification_email  = "finance@example.com"
}

run "owner_ids_list_every_listed_owner" {
  command = plan

  variables {
    github_owner_ids = ["1001", "2002"]
  }

  assert {
    condition = alltrue([for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) :
      jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:repository_owner_id"] == ["1001", "2002"]
    ])
    error_message = "both listed owner ids are in the trust and no other"
  }
}

run "owner_ids_repeat_one_owner_once" {
  command = plan

  variables {
    github_owner_ids = ["1001", "1001"]
  }

  assert {
    condition = alltrue([for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) :
      jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:repository_owner_id"] == ["1001"]
    ])
    error_message = "an owner listed twice appears once"
  }
}

run "single_owner_id_is_unchanged" {
  command = plan

  variables {
    github_owner_id = "1001"
  }

  assert {
    condition = alltrue([for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) :
      jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:repository_owner_id"] == "1001"
    ])
    error_message = "github_owner_id still sets one owner string"
  }
}

run "no_owner_means_no_owner_claim" {
  command = plan

  assert {
    condition = alltrue([for r in concat(values(aws_iam_role.plan), values(aws_iam_role.apply)) :
      !contains(keys(jsondecode(r.assume_role_policy).Statement[0].Condition.StringEquals), "token.actions.githubusercontent.com:repository_owner_id")
    ])
    error_message = "no owner id, no owner claim"
  }
}

run "both_owner_inputs_are_refused" {
  command = plan

  variables {
    github_owner_id  = "1001"
    github_owner_ids = ["1001", "2002"]
  }

  expect_failures = [var.github_owner_ids]
}

run "owner_ids_must_match_the_repositories" {
  command = plan

  variables {
    github_owner_ids = ["1001"]
  }

  expect_failures = [var.github_owner_ids]
}

run "extra_reads_reach_only_their_environment" {
  command = plan

  variables {
    workload_boundary_extra_actions = { dev = ["bedrock:GetAgent", "bedrock-agentcore:ListMemories"] }
  }

  assert {
    condition = (
      contains(flatten([for s in jsondecode(aws_iam_policy.workload_boundary["dev"].policy).Statement : s.Action if s.Sid == "WorkloadExtraReads"]), "bedrock:GetAgent") &&
      contains(flatten([for s in jsondecode(aws_iam_policy.workload_boundary["dev"].policy).Statement : s.Action if s.Sid == "WorkloadExtraReads"]), "bedrock-agentcore:ListMemories") &&
      length([for s in jsondecode(aws_iam_policy.workload_boundary["production"].policy).Statement : s if s.Sid == "WorkloadExtraReads"]) == 0
    )
    error_message = "the listed reads are in dev's boundary and not in production's"
  }
}

run "no_extra_reads_means_no_extra_statement" {
  command = plan

  assert {
    condition     = alltrue([for p in values(aws_iam_policy.workload_boundary) : length([for s in jsondecode(p.policy).Statement : s if s.Sid == "WorkloadExtraReads"]) == 0])
    error_message = "by default no boundary gains a statement"
  }
}

run "an_extra_write_action_is_refused" {
  command = plan

  variables {
    workload_boundary_extra_actions = { dev = ["bedrock:DeleteAgent"] }
  }

  expect_failures = [var.workload_boundary_extra_actions]
}

run "an_extra_wildcard_is_refused" {
  command = plan

  variables {
    workload_boundary_extra_actions = { dev = ["bedrock:Get*"] }
  }

  expect_failures = [var.workload_boundary_extra_actions]
}

run "an_extra_iam_read_is_refused" {
  command = plan

  variables {
    workload_boundary_extra_actions = { dev = ["iam:GetRole"] }
  }

  expect_failures = [var.workload_boundary_extra_actions]
}

run "an_extra_for_an_unknown_environment_is_refused" {
  command = plan

  variables {
    workload_boundary_extra_actions = { staging = ["bedrock:GetAgent"] }
  }

  expect_failures = [var.workload_boundary_extra_actions]
}

run "passrole_services_extend_the_list" {
  command = plan

  variables {
    passrole_services = ["bedrock-agentcore.amazonaws.com"]
  }

  assert {
    condition = alltrue([for e in ["dev", "production"] :
      [for s in jsondecode(aws_iam_role_policy.apply_workload_iam[e].policy).Statement : s.Condition.StringEquals["iam:PassedToService"] if s.Sid == "PassWorkloadRoles"][0] == ["lambda.amazonaws.com", "states.amazonaws.com", "bedrock-agentcore.amazonaws.com"]
    ])
    error_message = "the extra principal follows Lambda and Step Functions"
  }
}

run "passrole_default_is_lambda_and_states" {
  command = plan

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.apply_workload_iam["dev"].policy).Statement : s.Condition.StringEquals["iam:PassedToService"] if s.Sid == "PassWorkloadRoles"][0] == ["lambda.amazonaws.com", "states.amazonaws.com"]
    error_message = "by default only Lambda and Step Functions"
  }
}

run "a_passrole_service_must_be_an_amazonaws_principal" {
  command = plan

  variables {
    passrole_services = ["example.com"]
  }

  expect_failures = [var.passrole_services]
}

run "no_repositories_by_default" {
  command = plan

  assert {
    condition     = length(aws_ecr_repository.container) == 0 && length(output.container_repository_urls) == 0
    error_message = "no container_repositories, no registry"
  }
}

run "a_container_repository_is_immutable_scanned_and_pullable_by_lambda" {
  command = plan

  variables {
    container_repositories = ["shop-api"]
  }

  assert {
    condition     = aws_ecr_repository.container["shop-api"].image_tag_mutability == "IMMUTABLE" && aws_ecr_repository.container["shop-api"].image_scanning_configuration[0].scan_on_push && !aws_ecr_repository.container["shop-api"].force_delete && aws_ecr_repository.container["shop-api"].encryption_configuration[0].encryption_type == "AES256"
    error_message = "immutable tags, scan on push, AES256, no force delete"
  }

  assert {
    condition     = jsondecode(aws_ecr_lifecycle_policy.container["shop-api"].policy).rules[0].selection.tagStatus == "untagged"
    error_message = "the lifecycle policy expires untagged images only"
  }

  assert {
    condition     = jsondecode(aws_ecr_repository_policy.container["shop-api"].policy).Statement[0].Principal.Service == "lambda.amazonaws.com" && jsondecode(aws_ecr_repository_policy.container["shop-api"].policy).Statement[0].Condition.StringLike["aws:sourceArn"] == "arn:aws:lambda:ap-southeast-2:123456789012:function:*" && toset(jsondecode(aws_ecr_repository_policy.container["shop-api"].policy).Statement[0].Action) == toset(["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"])
    error_message = "only Lambda in this account and Region may pull, with two read actions"
  }
}

run "an_invalid_repository_name_is_refused" {
  command = plan

  variables {
    container_repositories = ["Shop API"]
  }

  expect_failures = [var.container_repositories]
}

run "an_extra_credential_action_is_refused" {
  command = plan

  variables {
    workload_boundary_extra_actions = { dev = ["redshift:GetClusterCredentials"] }
  }

  expect_failures = [var.workload_boundary_extra_actions]
}

run "a_code_running_passrole_service_is_refused" {
  command = plan

  variables {
    passrole_services = ["codebuild.amazonaws.com"]
  }

  expect_failures = [var.passrole_services]
}
