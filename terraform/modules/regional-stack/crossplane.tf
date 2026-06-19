# Crossplane v2 — RE-INTRODUCED fresh for NON-identity, workload-scoped cloud
# resources (ADR-22, WS4 Axis A). This is NOT the retired v1 IRSA stack.
#
# WHAT THIS IS / IS NOT
# ---------------------
# IS:  Crossplane v2 core + the upjet AWS provider family + provider-aws-s3, an
#      explicit MRAP activating ONLY the S3 namespaced MRDs, function-patch-and-
#      transform, fully-populated DeploymentRuntimeConfigs, a Pod-Identity-backed
#      ClusterProviderConfig, and the platform XBucket XRD/Composition
#      (charts/aegis-xrds-v2). The engine for workload buckets/queues/tables.
# NOT: the identity provisioner. ADR-21 §A + PR #117 moved workload IAM to EKS
#      Pod Identity + Terraform (pod-identity-engine.tf). Crossplane NEVER
#      re-owns identity, NEVER creates an IAM role/policy. The S3 provider's OWN
#      credentials come from a Terraform-owned Pod Identity role below — mirroring
#      pod-identity-engine.tf exactly (region-suffixed name, standard path `/`,
#      NOT /aegis-workload/). That standard-path + Terraform-owned-lifecycle is
#      precisely what stops the orphan-at-teardown the v1 stack hit (ADR-22
#      Context).
#
# ⚠️ VALIDATION PENDING ON A CLUSTER (WS4): offline-validated only (crossplane
# render + beta validate, terraform fmt/validate). NOT run against a live
# cluster. The on-cluster checklist is in the PR body / ADR-22 §Open validation.

# crossplane-system namespace with PSA=restricted ENFORCED from the start. This
# is the namespace whose restricted profile rejects an empty-securityContext
# provider/function pod — which is exactly why every DRC in the chart ships a
# non-empty securityContext (charts/aegis-xrds-v2/templates/deploymentruntimeconfig.yaml).
resource "kubernetes_namespace" "crossplane_system" {
  # Wait for the EKS access-entry -> authorizer propagation (eks.tf) before the
  # first cluster-scoped create — see kubernetes_namespace.argocd / run 27843245290.
  depends_on = [time_sleep.eks_access_propagation]

  metadata {
    name = "crossplane-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# Crossplane v2 core — the abstraction engine. Pinned to a v2.3.x chart; v2.3 is
# the current line (ADR-22 references). VERIFY the exact chart patch against
# https://charts.crossplane.io before the bootstrap apply (same convention as
# kyverno.tf / argo-rollouts.tf — a stale pin surfaces as a plan/install error,
# not silent drift).
#
# Crossplane's OWN pods (the core controller + RBAC manager) also run under
# crossplane-system's restricted PSA, so their podSecurityContext is set via
# chart values here — the same split the v1 stack used (chart values for
# Crossplane's pods; DRCs for the separately-deployed provider/function pods).
resource "helm_release" "crossplane" {
  name             = "crossplane"
  namespace        = kubernetes_namespace.crossplane_system.metadata[0].name
  create_namespace = false # created above with the PSA labels
  repository       = "https://charts.crossplane.io/stable"
  chart            = "crossplane"
  version          = "2.3.1" # pinned — VERIFY at bootstrap (charts.crossplane.io)

  # Restricted-PSA securityContext for Crossplane's own controller + RBAC-manager
  # pods. (Provider/function pods are separate Deployments — their securityContext
  # comes from the DRCs in the chart, not from here.)
  values = [yamlencode({
    securityContextCrossplane = {
      runAsNonRoot             = true
      runAsUser                = 65532
      runAsGroup               = 65532
      allowPrivilegeEscalation = false
      readOnlyRootFilesystem   = true
      seccompProfile           = { type = "RuntimeDefault" }
      capabilities             = { drop = ["ALL"] }
    }
    securityContextRBACManager = {
      runAsNonRoot             = true
      runAsUser                = 65532
      runAsGroup               = 65532
      allowPrivilegeEscalation = false
      readOnlyRootFilesystem   = true
      seccompProfile           = { type = "RuntimeDefault" }
      capabilities             = { drop = ["ALL"] }
    }
    # v2 ships MRDs Inactive by default; the MRAP in the chart activates only S3.
    # No extra Helm flag needed for that — the MRAP object does the gating.
  })]

  # Teardown safety — same posture as kyverno.tf / argo-rollouts.tf (A4): a helm
  # uninstall of an operator with webhooks/finalizers can deadlock terraform
  # destroy and strand a billing cluster. wait=false returns immediately; the
  # ephemeral-cluster teardown (infra-ops.yml) state-rm's the releases and lets
  # the cluster delete reap them. timeout bounds any residual wait.
  wait    = false
  timeout = 300

  # time_sleep (eks.tf) chains off module.eks AND adds the access-entry -> authorizer
  # propagation wait that the WS4 dual-region burn proved necessary (run 27843245290).
  depends_on = [time_sleep.eks_access_propagation]
}

# The platform XRD/Composition + provider + MRAP + DRC + ClusterProviderConfig
# chart. Separate release from crossplane core so a vocabulary change has a
# tighter blast radius than reinstalling the engine (same split as
# kyverno.tf's aegis_policies vs kyverno).
#
# The chart's cluster-scoped install-time values (region, accountId,
# bucketPrefix) are Helm-rendered into the Composition's bucket-name template +
# the provider region. Per-XR values (spec.name, spec.access) are
# Crossplane-patched at reconcile, not here.
resource "helm_release" "aegis_xrds_v2" {
  name      = "aegis-xrds-v2"
  namespace = kubernetes_namespace.crossplane_system.metadata[0].name
  chart     = "${path.module}/charts/aegis-xrds-v2"

  set {
    name  = "region"
    value = var.region
  }
  set {
    name  = "accountId"
    value = data.aws_caller_identity.current.account_id
  }
  # Bucket-name prefix — short, DNS-1123, the workload family marker. The
  # Composition builds "<prefix>-<spec.name>-<account>-<region>".
  set {
    name  = "bucketPrefix"
    value = "aegis-wl"
  }

  # A4 teardown posture (same as kyverno aegis_policies).
  wait    = false
  timeout = 300

  # The XRDs/Compositions/providers need crossplane core's CRDs (Provider,
  # Function, DeploymentRuntimeConfig, CompositeResourceDefinition,
  # ManagedResourceActivationPolicy) to exist first.
  depends_on = [helm_release.crossplane]
}

# ── Crossplane S3 provider IAM via EKS Pod Identity ─────────────────────────
# Mirrors pod-identity-engine.tf EXACTLY: a Terraform-owned aws_iam_role
# (region-suffixed name, standard path `/`, pods.eks.amazonaws.com trust) + an
# aws_eks_pod_identity_association binding it to the provider's stable SA in
# crossplane-system. This grants the upjet S3 provider pod its AWS permissions
# the right way — destroyed cleanly with the stack, NO /aegis-workload/, NO SCP
# carve-out, NO orphan-at-teardown (the v1 failure mode, ADR-22 Context).

# Same fixed Pod Identity trust principal as the engine (pod-identity-engine.tf).
data "aws_iam_policy_document" "crossplane_s3_provider_pod_identity_trust" {
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

resource "aws_iam_role" "crossplane_s3_provider" {
  # Region-suffixed (IAM is a global namespace; two regions in one account would
  # collide on a bare name — same class pod-identity-engine.tf documents).
  # Standard path `/`, NOT /aegis-workload/.
  name               = "aegis-crossplane-s3-${var.region}"
  assume_role_policy = data.aws_iam_policy_document.crossplane_s3_provider_pod_identity_trust.json
  description        = "EKS Pod Identity role for the Crossplane upjet S3 provider in ${var.region} (ADR-22 WS4 Axis A). Terraform-owned, destroyed cleanly with the stack - NOT /aegis-workload/, no orphan-at-teardown."

  tags = local.common_tags
}

# The S3 permissions the provider needs to CRUD the buckets XBucket composes.
# Scoped to the workload-bucket name prefix this region uses
# (aegis-wl-*-<account>-<region>) so the provider cannot touch arbitrary buckets
# (e.g. the Terraform-owned model bucket, the tfstate bucket). The provider also
# needs tagging + public-access-block + GET on its managed buckets to reconcile.
data "aws_iam_policy_document" "crossplane_s3_provider" {
  statement {
    sid    = "ManageWorkloadBuckets"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:DeleteBucket",
      "s3:ListBucket",
      "s3:GetBucketTagging",
      "s3:PutBucketTagging",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketPublicAccessBlock",
      "s3:GetBucketAcl",
      "s3:GetBucketPolicy",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
      "s3:GetBucketLocation",
      "s3:GetAccelerateConfiguration",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketLogging",
      "s3:GetLifecycleConfiguration",
      "s3:GetReplicationConfiguration",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketCORS",
      "s3:GetBucketWebsite",
    ]
    # Scoped to this region's workload-bucket name prefix. account_id is in the
    # name so a wildcard ARN still cannot reach another account's buckets.
    resources = [
      "arn:aws:s3:::aegis-wl-*-${data.aws_caller_identity.current.account_id}-${var.region}",
    ]
  }
}

resource "aws_iam_policy" "crossplane_s3_provider" {
  name        = "aegis-crossplane-s3-${var.region}"
  description = "S3 CRUD for the Crossplane upjet S3 provider, scoped to this region's workload-bucket name prefix (ADR-22 WS4 Axis A)."
  policy      = data.aws_iam_policy_document.crossplane_s3_provider.json

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "crossplane_s3_provider" {
  role       = aws_iam_role.crossplane_s3_provider.name
  policy_arn = aws_iam_policy.crossplane_s3_provider.arn
}

# The association — binds the role to the provider's stable SA name in
# crossplane-system. The SA name (provider-aws-s3) is fixed by the
# provider-aws-s3-runtime DeploymentRuntimeConfig (chart). Let Crossplane
# auto-name the SA and this binding no longer matches → the provider gets no
# credentials. Its lifecycle is the cluster + this stack — destroy deletes it
# with the role, leaving zero orphan IAM.
resource "aws_eks_pod_identity_association" "crossplane_s3_provider" {
  cluster_name    = module.eks.cluster_name
  namespace       = kubernetes_namespace.crossplane_system.metadata[0].name
  service_account = "provider-aws-s3"
  role_arn        = aws_iam_role.crossplane_s3_provider.arn

  tags = local.common_tags
}
