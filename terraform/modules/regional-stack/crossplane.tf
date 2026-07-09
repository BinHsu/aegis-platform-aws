# Crossplane v2 — install MIGRATED TO GITOPS; provider IAM stays (epic #167 A3 /
# issue #175, ADR-25 ownership inversion).
#
# ─────────────────────────────────────────────────────────────────────────────
# This file previously held the Crossplane INSTALL: three helm_release resources,
# a time_sleep gate, and a namespace —
#   - helm_release.crossplane                    (core controller + CRDs)
#   - kubernetes_namespace.crossplane_system     (PSA=restricted namespace)
#   - helm_release.aegis_xrds_v2_definitions     (providers, function, DRCs, MRAP,
#                                                 XRD, Composition)
#   - time_sleep.crossplane_providers_healthy    (300s wait for provider Healthy)
#   - helm_release.aegis_xrds_v2_providerconfig  (ClusterProviderConfig)
# ADR-25 ownership inversion moved ALL of that out of Terraform into ArgoCD, as
# three app-of-apps children under gitops/platform-addons/addons/crossplane/
# (unlike kyverno/argo-rollouts these are ApplicationSets — see WHAT MOVED WHERE):
#   - applicationset-core.yaml            (sync-wave 0)
#   - applicationset-definitions.yaml     (sync-wave 1)
#   - applicationset-providerconfig.yaml  (sync-wave 2)
# The app-of-apps root that delivers them: gitops/platform-addons/root-app.yaml,
# seeded from Terraform in gitops-bootstrap.tf (the A1 #173 facts-bridge bootstrap;
# this PR adds an account-id annotation there for the definitions stage).
#
# WHY: Terraform owning these in-cluster objects is exactly the ownership mismatch
# epic #167 dissolves — `terraform destroy` no longer helm-uninstalls Crossplane
# (the cluster delete reaps it), so the state-rm loop that unwound it is no longer
# needed for this add-on. The old wait/teardown posture is preserved structurally
# in the Applications (no resources-finalizer → no foreground cascade).
#
# WHAT MOVED WHERE:
#   - chart pin (crossplane 2.3.1)         → core app source.targetRevision
#   - securityContextCrossplane/RBACManager → core app helm.valuesObject
#   - crossplane-system ns + PSA=restricted → core app managedNamespaceMetadata +
#     labels                                  syncOptions CreateNamespace=true
#   - installStage=definitions + region/     → definitions ApplicationSet (region +
#     accountId/bucketPrefix (were TF `set`)   accountId from the FACTS BRIDGE, so
#                                              the git manifest stays cluster-agnostic;
#                                              bucketPrefix static — A1 Alloy shape)
#   - installStage=providerconfig            → providerconfig ApplicationSet
#   - CRD-establishment barrier (core        → ArgoCD sync-waves 0 → 1 + ServerSideApply
#     wait=true / depends_on)                  (the crossplane CRDs exceed 256 KB)
#   - time_sleep 300s before ClusterProvider  → RETRY-UNTIL-HEALTHY on the wave-2 app:
#     Config (blind wall-clock wait)           its sync fails until aws.m.upbound.io
#                                              is established (provider Healthy), then
#                                              a retry succeeds — condition-driven, no
#                                              stopwatch (applicationset-providerconfig.yaml)
#   - fan-out gating (keep Crossplane out of  → `clusters` generator on the facts-bridge
#     the bare A2/B1 policy harness)           Secret — no cluster Secret, no Crossplane
#                                              (same gate Alloy uses)
#
# WHAT STAYED IN TERRAFORM (this file, below): the S3-provider IAM — an EKS Pod
# Identity role/policy/association. Unlike kyverno/argo-rollouts (which kept
# nothing), Crossplane's provider pod calls AWS, so it needs an IAM role. That role
# is ACCOUNT INFRASTRUCTURE, not cluster state (issue #175): region-suffixed,
# standard path `/`, Terraform-owned, destroyed cleanly with the stack — NEVER a
# Crossplane claim, NEVER /aegis-workload/, NO orphan-at-teardown (the v1 failure
# mode, ADR-22 Context). Identity stays out of the no-`plan` engine (where a silent
# delete is catastrophic). The cluster access-entries that let the pods run live in
# eks.tf, unaffected.
#
# ⚠️ SA NAME `provider-aws-s3` IS LOAD-BEARING: the aws_eks_pod_identity_association
# below binds the role to (crossplane-system, provider-aws-s3). That SA name is
# fixed by the provider-aws-s3-runtime DeploymentRuntimeConfig
# (charts/aegis-xrds-v2/templates/deploymentruntimeconfig.yaml). Rename either side
# and the Pod Identity trust breaks SILENTLY — the provider gets no credentials and
# every Bucket MR AccessDenies.
#
# REVERT: `git revert` restores the 3 helm_release resources, the time_sleep, and
# the crossplane_system namespace here (and the `time` provider in versions.tf +
# the account-id annotation in gitops-bootstrap.tf), and removes the three GitOps
# ApplicationSets. The provider IAM below is unchanged by the migration. Single
# logical boundary.

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
# auto-name the SA and this binding no longer matches -> the provider gets no
# credentials. Its lifecycle is the cluster + this stack — destroy deletes it
# with the role, leaving zero orphan IAM.
#
# The namespace is a LITERAL "crossplane-system" (not a
# kubernetes_namespace.crossplane_system reference) since A3 moved that namespace
# to ArgoCD ownership (applicationset-core.yaml managedNamespaceMetadata). The name is
# a stable contract shared by the Pod Identity association and the GitOps core app.
resource "aws_eks_pod_identity_association" "crossplane_s3_provider" {
  cluster_name    = module.eks.cluster_name
  namespace       = "crossplane-system"
  service_account = "provider-aws-s3"
  role_arn        = aws_iam_role.crossplane_s3_provider.arn

  tags = local.common_tags
}
