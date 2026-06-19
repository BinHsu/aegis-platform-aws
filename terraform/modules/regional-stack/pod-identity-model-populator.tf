# Model-populator workload IAM via EKS Pod Identity (Phase 4c — ADR-18 AWS twin).
#
# WHY A SEPARATE IDENTITY. model-store.tf creates the per-region model bucket
# EMPTY; the engine's model-fetch init does `aws s3 sync s3://<bucket> /models`
# and fails LOUD on an empty bucket (delivery-layer assertion). On-prem the
# minio-bootstrap Job seeds the equivalent MinIO bucket from HuggingFace; the
# AWS side had no twin (the "Phase 4c CI model populator, gated on ldz #85"
# comment in aegis-core-deploy). This is that twin — but in-cluster, not CI.
#
# The populator runs as a one-shot Job (aegis-core-deploy aws-binding
# model-populate-job.yaml) under its OWN ServiceAccount, bound to THIS role by
# an EKS Pod Identity association. It is the ONLY identity with WRITE on the
# model bucket. The engine role (pod-identity-engine.tf) stays READ-ONLY — the
# read/write split is the whole point: a compromised engine cannot rewrite the
# models it loads.
#
# PER-REGION + DR. The regional-stack module is instantiated once per enabled
# region, so this role + association land in every region the platform brings
# up, including a cold DR region. No CI step, no out-of-band AWS creds, no ldz
# IAM grant: EKS Pod Identity issues the credentials in-cluster, and the role
# is plain Terraform (destroyed cleanly with the stack — same lifecycle posture
# as the engine role, no Crossplane /aegis-workload/ orphan class).

# The populator binds to a DEDICATED ServiceAccount in the engine namespace.
# Distinct from the engine SA so the write grant never widens the engine's
# identity. The name is a constant of the aegis-core-deploy contract.
locals {
  model_populator_service_account = "aegis-core-model-populator"
}

# Write policy — scoped to EXACTLY this region's model bucket, the three verbs
# the populator needs and no more:
#   - s3:ListBucket  — list the bucket to drive idempotency (does the CAS key
#                      already exist before uploading?).
#   - s3:HeadObject  — the per-object existence probe (`aws s3api head-object`)
#                      the Job uses to skip an already-present model.
#   - s3:PutObject   — upload the model artifact to the CAS key.
# No GetObject, no DeleteObject, no bucket-policy/ACL verbs. This is the write
# half of the read/write split; the engine keeps GetObject+ListBucket only.
data "aws_iam_policy_document" "model_write" {
  statement {
    sid       = "ListModelBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.models.arn]
  }
  statement {
    sid       = "WriteModelObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.models.arn}/*"]
  }
}

# s3:HeadObject is not a distinct IAM action — the S3 HeadObject API authorizes
# against s3:GetObject. The populator's existence probe (`aws s3api head-object`)
# therefore needs s3:GetObject on the object ARNs, granted above alongside
# PutObject. GetObject here is on the POPULATOR identity only (to read-back /
# probe what it wrote); the engine's separate read-only role is unchanged. The
# bucket is private (public-access-block on, model-store.tf), so this is not a
# data-exposure widening — it is the minimum the head-object idempotency check
# requires.

resource "aws_iam_policy" "model_write" {
  # Region-suffixed for the same reason as model-read / engine (IAM is a global
  # namespace; two regions in one account would collide on a bare name —
  # the #108 / ADR-21 §C EntityAlreadyExists class).
  name        = "aegis-core-model-write-${var.region}"
  description = "Write access (Put/List/Head) to the aegis-core engine model bucket in ${var.region}, for the in-cluster model-populator Job (Phase 4c, ADR-18 AWS twin). Separate from the read-only engine role."
  policy      = data.aws_iam_policy_document.model_write.json

  tags = local.common_tags
}

# Pod Identity trust — identical principal to the engine role (the Pod Identity
# Agent service principal, fixed across regions, no per-cluster OIDC issuer).
data "aws_iam_policy_document" "model_populator_pod_identity_trust" {
  statement {
    sid     = "EksPodIdentityAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "model_populator" {
  # Region-suffixed (ADR-21 §C precedent). Terraform-owned at the module's
  # standard path (/), destroyed cleanly with the stack — no /aegis-workload/
  # path, no SCP wall, no orphan on teardown.
  name               = "aegis-core-model-populator-${var.region}"
  assume_role_policy = data.aws_iam_policy_document.model_populator_pod_identity_trust.json
  description        = "EKS Pod Identity role for the in-cluster model-populator Job in ${var.region} (Phase 4c, ADR-18 AWS twin). Write-only-to-the-model-bucket; separate from the read-only engine role."

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "model_populator_write" {
  role       = aws_iam_role.model_populator.name
  policy_arn = aws_iam_policy.model_write.arn
}

# The association binds the write role to the dedicated populator SA through the
# EKS control-plane API (eks-pod-identity-agent add-on). Lifecycle = the cluster
# + this stack; teardown deletes it with the role, leaving zero orphan IAM.
resource "aws_eks_pod_identity_association" "model_populator" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.engine_namespace
  service_account = local.model_populator_service_account
  role_arn        = aws_iam_role.model_populator.arn

  tags = local.common_tags
}
