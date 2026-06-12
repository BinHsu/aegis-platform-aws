# ============================================================================
# CI IAM roles — SEEDED BY envs/bootstrap, referenced here by data source (ADR-13)
#
# The GitHub OIDC trust + the four CI roles (gh-tf-apply-platform,
# gh-tf-destroy-platform, the read-only plan role, the greeter ECR push role)
# USED to be `resource` blocks in this file. They were destroyed by
# `destroy-platform`, which on 2026-06-12 produced four live failures (run
# record: docs/runbooks/2026-06-12-joint-strike.md §G): a self-delete hazard, an
# orphaned admin destroy role in both accounts, a cold-start chicken-egg (no
# OIDC path left after teardown), and an infra-plan red light.
#
# ADR-13 relocates the role definitions to envs/bootstrap (LOCAL state, the
# operator-applied seed layer that survives teardown-to-zero). This file now
# only LOOKS THEM UP so that:
#   - outputs.tf can keep re-exporting the ARNs (downstream regional/ reads them
#     from the platform remote state — its cluster-access roster is unchanged),
#   - budget.tf can attach the cost-freeze action to gh-tf-apply-platform, and
#   - destroy-policy.tf can reference gh-tf-destroy-platform.
#
# A `terraform destroy` of this env removes only data sources (a no-op against
# the live roles) — the seed roles persist. That is the structural fix: the
# destroy can no longer delete the role it runs as, nor the roles the next cycle
# needs to assume.
#
# DEPENDENCY: envs/bootstrap must have been applied in this account first — it
# is already a precondition, since bootstrap creates the state bucket this env's
# backend uses. The roles therefore always exist before any platform apply.
# ============================================================================

data "aws_iam_role" "greeter_ci" {
  name = "aegis-greeter-ci"
}

data "aws_iam_role" "infra_ci" {
  name = "aegis-platform-aws-ci"
}

data "aws_iam_role" "infra_apply" {
  name = "gh-tf-apply-platform"
}

data "aws_iam_role" "infra_destroy" {
  name = "gh-tf-destroy-platform"
}
