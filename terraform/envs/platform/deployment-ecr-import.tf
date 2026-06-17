# One-time adoption (WS3 first apply) of the shared-registry greeter resources.
#
# WHY: the aegis-greeter ECR repo + aegis-greeter-ci-push push role were seeded
# in the aegis-deployment account under the PRE-W3 single-state topology and
# survived the 2026-06-12 cluster teardown (a cluster-account teardown deletes
# the cluster, NOT the deployment account's ECR repos / IAM roles). The fresh
# per-account platform state (bootstrapped 2026-06-17) had no record of them, so
# the first staging apply failed with RepositoryAlreadyExistsException /
# EntityAlreadyExists. These import blocks ADOPT the existing resources into
# state instead of recreating them. The aegis-core equivalents were never seeded
# this way, so they create normally — no import needed.
#
# Gated on local.deployment_enabled (the same single-owner gate as the resources
# in deployment-ecr.tf): the import only runs on the account that owns the shared
# registry (staging). On accounts where the gate is off the target [0] instance
# does not exist, so the import must not be generated — hence the for_each toggle.
#
# SAFE TO LEAVE: once imported, Terraform treats an import block whose target is
# already in state as a no-op, so re-applies do nothing. The dependent resources
# (repository_policy, lifecycle_policy, inline role policy) are Put*-idempotent,
# so they converge on apply without their own import blocks. Remove in a later
# cleanup PR once staging is confirmed converged.

import {
  for_each = local.deployment_enabled == 1 ? toset(["greeter"]) : toset([])
  to       = aws_ecr_repository.shared_greeter[0]
  id       = var.ecr_repository_name # repository name = import id for aws_ecr_repository
}

import {
  for_each = local.deployment_enabled == 1 ? toset(["greeter"]) : toset([])
  to       = aws_iam_role.shared_greeter_push[0]
  id       = "aegis-greeter-ci-push" # role name = import id for aws_iam_role
}
