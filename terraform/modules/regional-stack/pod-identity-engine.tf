# Engine workload IAM via EKS Pod Identity (ADR-21 §A).
#
# ROOT-CAUSE FIX for the orphaned Crossplane-composed IRSA role. Before this,
# the engine's IAM role was composed IN-CLUSTER by Crossplane: a WorkloadIdentity
# claim rendered an upjet iam.aws.upbound.io/Role at IAM path /aegis-workload/.
# Because the Crossplane CONTROLLER (not Terraform) owned that role, a cluster
# teardown removed the controller BEFORE it reconcile-deleted the role — leaving
# an orphan in /aegis-workload/ that an org SCP then blocks from manual delete,
# and whose attached aegis-core-model-read-<region> policy name collides on the
# next cold-start apply (EntityAlreadyExists). See ADR-21 §A.1.
#
# Pod Identity puts the role in the RIGHT lifecycle layer: a normal Terraform
# aws_iam_role, destroyed cleanly with the stack. The association binds the role
# to the engine ServiceAccount through the EKS control-plane API via the
# eks-pod-identity-agent add-on (eks.tf) — no OIDC trust authoring, no in-cluster
# IAM controller, no /aegis-workload/ path, no SCP wall, no name collision.
#
# The deploy side (aegis-core-deploy PR #22) made the SA `aegis-core-engine`
# BARE: no eks.amazonaws.com/role-arn annotation, no WorkloadIdentity claim. It
# now gets its identity purely from the Pod Identity association below. The
# provider-neutral injection contract (ADR-16) is unchanged — the platform still
# binds identity to that exact SA; only the MECHANISM changed.
#
# MERGE ORDER: this platform PR merges BEFORE aegis-core-deploy #22. If the bare
# SA lands first, the engine has no identity until this association exists.
#
# ⚠️ VALIDATION PENDING ON A CLUSTER (WS4): this has NOT run against a live
# cluster. See the PR body's "VALIDATION REQUIRED ON A CLUSTER (WS4)" checklist.

# The engine workload binds to this fixed namespace + ServiceAccount on this
# cluster. They are constants of the aegis-core deploy contract (ns aegis-core,
# SA aegis-core-engine), not per-region values.
locals {
  engine_namespace       = "aegis-core"
  engine_service_account = "aegis-core-engine"
}

# Pod Identity trust policy — the FIXED Pod Identity principal, identical across
# regions (no per-cluster OIDC issuer to thread). pods.eks.amazonaws.com is the
# Pod Identity Agent's principal; sts:TagSession is required alongside
# sts:AssumeRole so the agent can attach the session tags EKS injects.
data "aws_iam_policy_document" "engine_pod_identity_trust" {
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

resource "aws_iam_role" "engine" {
  # Region-suffixed (ADR-21 §C precedent; same class the dual-region apply hit
  # on aegis-core-model-read-<region>): IAM is a global namespace, so two
  # regions in one account would collide on a bare name. NOT under
  # /aegis-workload/ — that path is the Crossplane/SCP seam this migration
  # leaves behind; a Terraform-owned role uses the module's standard path (/).
  name               = "aegis-core-engine-${var.region}"
  assume_role_policy = data.aws_iam_policy_document.engine_pod_identity_trust.json
  description        = "EKS Pod Identity role for the aegis-core engine in ${var.region} (ADR-21 §A — replaces the Crossplane-composed IRSA role). Terraform-owned, destroyed cleanly with the stack."

  tags = local.common_tags
}

# Attach the existing per-region model-read managed policy (model-store.tf). The
# engine's only AWS API surface is `aws s3 sync` from its in-region model bucket;
# this policy grants exactly s3:ListBucket + s3:GetObject on that bucket.
#
# Attaching the SHARED managed policy (vs an inline policy) keeps a single source
# of truth for the model-read grant and matches how the Crossplane path consumed
# it (the WorkloadIdentity claim's policyArns). The EntityAlreadyExists collision
# ADR-21 §A.1 names came from the ORPHANED ROLE re-creating, not from the policy
# itself — with the role now Terraform-managed and torn down cleanly, the policy
# name is free on every cold start.
resource "aws_iam_role_policy_attachment" "engine_model_read" {
  role       = aws_iam_role.engine.name
  policy_arn = aws_iam_policy.model_read.arn
}

# The association — the EKS control-plane binding of the role to the SA. Its
# lifecycle is the cluster (+ this stack); a `terraform destroy` deletes it
# alongside the role, so teardown leaves zero orphan IAM.
resource "aws_eks_pod_identity_association" "engine" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.engine_namespace
  service_account = local.engine_service_account
  role_arn        = aws_iam_role.engine.arn

  tags = local.common_tags
}
