# ADR-09 Phase 2 — Crossplane CORE ONLY.
#
# Crossplane in this architecture is a pure Kubernetes-internal abstraction
# engine: it reconciles platform-defined XRs (e.g. WorkloadIdentity) into ACK
# CRDs (iam.services.k8s.aws/Role) and stops there. It never calls AWS, holds
# no AWS credentials, no IRSA, no SCP carve-out — the four-pack stays with
# ACK (irsa-ack-iam.tf, the management-tier SCP carve-out, the Kyverno
# trust-subject policy, the default-deny NetworkPolicy). See ADR-09 Phase 2.
#
# Deliberately NOT installed here:
#   - provider-aws (no AWS API calls — Compositions render into ACK CRDs)
#   - ProviderConfig (no provider)
#   - Any Crossplane-side IRSA / SCP carve-out
#
# The aegis-xrds chart (sibling resource below) ships the WorkloadIdentity
# XRD + Composition + the function-patch-and-transform Function package
# Crossplane uses to render the Composition.
#
# ⚠️ implemented, E2E PENDING platform bootstrap.

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

  depends_on = [helm_release.crossplane]
}
