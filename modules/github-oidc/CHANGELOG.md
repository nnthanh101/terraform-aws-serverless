# Changelog

All notable changes to this module will be documented in this file.

## [Unreleased]

### Added

* `apply_allowed_refs` variable: configurable ref/environment claim list for the apply role trust boundary; defaults to `["ref:refs/heads/main"]` (CA decision D3). Callers can supply GitHub environment claims (e.g. `"environment:production"`) for an additional human-approval gate via environment-protection reviewers.

## [0.1.0] - 2026-06-10

### Features

* Initial implementation: GitHub Actions OIDC provider + split-trust plan/apply IAM roles
* `create_oidc_provider` bool for accounts that already have one (one-per-account constraint)
* Plan role defaults to `ReadOnlyAccess`; apply role requires caller-supplied `apply_policy_arns`
* Ref-narrowing trust on apply role: `ref:refs/heads/main` only (CI-apply safety boundary)
* Tier 1 tftest assertions validate split-trust sub-condition boundary
