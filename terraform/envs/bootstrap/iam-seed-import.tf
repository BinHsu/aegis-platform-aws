# ============================================================================
# One-time adoption (prod cold-start) of the IAM CI roles seeded by iam-seed.tf.
#
# WHY: the prod account (506221082337) had its bootstrap Terraform STATE cleared,
# but the five CI roles iam-seed.tf manages still EXIST as live AWS resources
# (survivors — IAM roles are account-global and outlived the state, exactly like
# the deployment-account ECR survivors in envs/platform/deployment-ecr-import.tf).
# A prod cold-start `terraform apply` of this bootstrap layer would otherwise
# fail EntityAlreadyExists when it tries to CREATE each role that already exists.
# These import blocks ADOPT the existing roles into state instead. After import,
# apply UPDATEs each role in place to match the declared config (a no-op if the
# live trust/permission policy already matches) — no recreate, no manual surgery.
#
# GATE: these survivors exist on THIS prod cold-start but NOT on a fresh account
# (a clean account creates the roles normally — no import needed, and an import
# of a non-existent role fails). So the import must be TOGGLEABLE, OFF by default.
# Gated on var.adopt_seeded_iam_roles via the same for_each toggle as
# envs/platform/deployment-ecr-import.tf: when false, toset([]) generates no
# import block at all; when true, each block adopts its survivor.
#
# ONE-TIME: set var.adopt_seeded_iam_roles=true only for the prod cold-start
# apply (CI tfvar / TF_VAR_adopt_seeded_iam_roles). Once prod state is
# reconciled, REMOVE this file and the variable in a later cleanup PR — an import
# block whose target is already in state is a no-op, so leaving it is harmless
# but it has served its single purpose.
#
# NOT IMPORTED — the inline role policies / policy attachments (greeter_ci,
# infra_ci_readonly, infra_apply_admin, infra_destroy_admin, core_frontend) are
# Put*-idempotent: apply converges them onto the adopted roles without their own
# import blocks (same reasoning as deployment-ecr-import.tf).
#
# NOT IMPORTED — `github-actions-aegis-core-ecr` is a deliberate exclusion. It is
# an orphan with no .tf home: the GHCR pivot (see docs/adr — supersedes ADR-10)
# makes the aegis-core ECR push role obsolete, so it is deletable, not adopted.
# ============================================================================

# Resource name = import id for aws_iam_role. Each `to` address is confirmed
# present in iam-seed.tf.

# Role A: aegis-greeter CI -> ECR push
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["greeter_ci"]) : toset([])
  to       = aws_iam_role.greeter_ci
  id       = "aegis-greeter-ci"
}

# Role B: aegis-platform-aws CI plan -> read-only AWS
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["infra_ci"]) : toset([])
  to       = aws_iam_role.infra_ci
  id       = "aegis-platform-aws-ci"
}

# Role C: gh-tf-apply-platform CI apply -> admin scoped to main
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["infra_apply"]) : toset([])
  to       = aws_iam_role.infra_apply
  id       = "gh-tf-apply-platform"
}

# Role D: gh-tf-destroy-platform — teardown, gated by human approval
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["infra_destroy"]) : toset([])
  to       = aws_iam_role.infra_destroy
  id       = "gh-tf-destroy-platform"
}

# Role F: github-actions-aegis-core-frontend — S3 frontend sync + CF invalidation
import {
  for_each = var.adopt_seeded_iam_roles ? toset(["core_frontend"]) : toset([])
  to       = aws_iam_role.core_frontend
  id       = "github-actions-aegis-core-frontend"
}
