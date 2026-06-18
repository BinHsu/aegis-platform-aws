# ADR-09 Phase 2 — Crossplane core + the upjet AWS IAM provider (fix B).
#
# fix B (live-proven 2026-06-18) replaced ACK with Crossplane's own upjet
# provider `provider-aws-iam`. The WorkloadIdentity Composition now renders a
# CLUSTER-scoped iam.aws.upbound.io/Role (not the namespaced ACK
# iam.services.k8s.aws/Role): a cluster-scoped XR composing a namespaced MR
# forced spec.resourceRefs[].namespace, which the XR CRD schema rejected. The
# upjet Role is cluster-scoped, so that schema error is gone.
#
# Unlike the original Phase 2 design, Crossplane is NO LONGER credential-free.
# provider-aws-iam DOES call AWS IAM, and gets creds via IRSA — reusing the
# existing role in irsa-ack-iam.tf (whose name keeps the
# `aegis-platform-aws-ack-iam-` prefix so the fabric SCP carve-out still
# matches), repointed to the provider's stable SA
# crossplane-system:provider-aws-iam. ACK is removed (ack-iam.tf deleted).
#
# Installed here:
#   - crossplane core (this file)
#   - aegis-xrds chart: WorkloadIdentity XRD + Composition + the
#     function-patch-and-transform Function + the provider-aws-iam Provider CR
#     + its DeploymentRuntimeConfigs (default + provider-aws-iam-runtime)
#   - aegis-aws-providerconfig chart: the aws.upbound.io ProviderConfig (a
#     separate chart, applied after a wait — its CRD only exists once the
#     provider installs)
#
# ⚠️ E2E proven on staging 2026-06-18; PENDING per-account bootstrap elsewhere.

resource "kubernetes_namespace" "crossplane_system" {
  metadata {
    name = "crossplane-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "helm_release" "crossplane" {
  # B1 (2026-06-11): the heavy platform controllers install in parallel and
  # deadline on the default 300s helm timeout during a busy cluster bring-up
  # ("context deadline exceeded"). 600s gives them room.
  timeout    = 600
  name       = "crossplane"
  namespace  = kubernetes_namespace.crossplane_system.metadata[0].name
  repository = "https://charts.crossplane.io/stable"
  chart      = "crossplane"
  version    = "1.20.8" # pinned — verify at bootstrap

  # PSA-restricted compliance (live-diagnosed 2026-06-12 — the real root cause
  # behind the 2026-06-10/06-11 "context deadline exceeded" failures; capacity,
  # timeout, and image-rot were all misdiagnoses).
  #
  # kubernetes_namespace.crossplane_system enforces pod-security.kubernetes.io/
  # enforce=restricted (defensive posture, by design — we do NOT downgrade the
  # policy to fix chart deficiencies). Crossplane 1.20.8 omits three fields
  # required by the restricted profile: pod-level runAsNonRoot and seccompProfile,
  # and container-level capabilities.drop. The API server rejects every pod
  # synchronously with "forbidden: violates PodSecurity "restricted:latest"" —
  # zero pods are ever scheduled, helm wait=600s exhausts, apply fails.
  #
  # These six set blocks supply the missing fields via chart-native value paths
  # (confirmed in `helm show values crossplane-stable/crossplane --version 1.20.8`).
  # They MERGE with the chart's existing security context defaults (runAsUser,
  # allowPrivilegeEscalation=false, readOnlyRootFilesystem), not replace them.
  # Alternative rejected: downgrading the namespace PSA label to baseline/privileged
  # trades a real security control to paper over a chart gap — fix the chart values.
  set {
    name  = "podSecurityContextCrossplane.runAsNonRoot"
    value = "true"
  }
  set {
    name  = "podSecurityContextCrossplane.seccompProfile.type"
    value = "RuntimeDefault"
  }
  set {
    name  = "securityContextCrossplane.capabilities.drop[0]"
    value = "ALL"
  }
  set {
    name  = "podSecurityContextRBACManager.runAsNonRoot"
    value = "true"
  }
  set {
    name  = "podSecurityContextRBACManager.seccompProfile.type"
    value = "RuntimeDefault"
  }
  set {
    name  = "securityContextRBACManager.capabilities.drop[0]"
    value = "ALL"
  }

  depends_on = [module.eks]
}

# ---- aegis-xrds: platform XRDs + Compositions + the Function they need -----
#
# This chart bundles:
#   - The function-patch-and-transform Function package (CRD installed by
#     Crossplane core; the package itself comes from xpkg.crossplane.io).
#   - The WorkloadIdentity XRD (Claim + cluster-scoped XR).
#   - The Composition that renders WorkloadIdentity into an ACK Role,
#     templating the IRSA trust policy with this cluster's OIDC provider.
#
# OIDC values are Helm-rendered at chart install time (not patched at runtime)
# because they are cluster-scoped, not workload-scoped — every Composition
# instance in this cluster uses the same OIDC provider.

resource "helm_release" "aegis_xrds" {
  # B1 (2026-06-11): the heavy platform controllers install in parallel and
  # deadline on the default 300s helm timeout during a busy cluster bring-up
  # ("context deadline exceeded"). 600s gives them room.
  timeout   = 600
  name      = "aegis-xrds"
  namespace = helm_release.crossplane.namespace
  chart     = "${path.module}/charts/aegis-xrds"

  set {
    name  = "oidcProviderArn"
    value = module.eks.oidc_provider_arn
  }

  set {
    name  = "oidcProviderHost"
    value = module.eks.oidc_provider
  }

  # The Composition's rendered Role lives in /aegis-workload/ — same path the
  # ACK controller's policy is scoped to (irsa-ack-iam.tf). The path is a value
  # so the chart stays parametric if the SCP carve-out ever shifts.
  set {
    name  = "iamRolePath"
    value = "/aegis-workload/"
  }

  # fix B: the provider-aws-iam-runtime DRC stamps this ARN onto the provider
  # SA's eks.amazonaws.com/role-arn annotation so the provider assumes the
  # reused irsa-ack-iam role via IRSA.
  set {
    name  = "providerRoleArn"
    value = module.irsa_ack_iam.arn
  }

  depends_on = [helm_release.crossplane]
}

# The aws.upbound.io/v1beta1/ProviderConfig CRD does not exist until
# provider-aws-iam (shipped by aegis-xrds above) downloads, pulls its
# upbound-provider-family-aws dependency, and Crossplane establishes both
# packages' CRDs. Applying the ProviderConfig chart immediately would 404 with
# "no matches for kind ProviderConfig". 150s covers the package download + CRD
# establishment observed during the 2026-06-18 bring-up.
resource "time_sleep" "wait_provider_crds" {
  depends_on      = [helm_release.aegis_xrds]
  create_duration = "150s"
}

# ProviderConfig (separate chart) — installs only after the provider CRDs exist.
resource "helm_release" "aegis_aws_providerconfig" {
  timeout    = 600
  name       = "aegis-aws-providerconfig"
  namespace  = helm_release.crossplane.namespace
  chart      = "${path.module}/charts/aegis-aws-providerconfig"
  depends_on = [time_sleep.wait_provider_crds]
}
