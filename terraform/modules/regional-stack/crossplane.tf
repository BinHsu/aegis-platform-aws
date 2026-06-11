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
  wait       = false # DIAG (2026-06-11): unblock the apply so the cluster comes up and crossplane is observable live; final state restores wait once the rot is fixed
  name       = "crossplane"
  namespace  = kubernetes_namespace.crossplane_system.metadata[0].name
  repository = "https://charts.crossplane.io/stable"
  chart      = "crossplane"
  version    = "1.20.8" # pinned — verify at bootstrap

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
  wait      = false # DIAG (2026-06-11)
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
