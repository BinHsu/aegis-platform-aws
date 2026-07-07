# GitOps bootstrap + facts bridge (ADR-25 ownership inversion, epic #167, A1).
#
# Terraform's job after the inversion is to own the CLUSTER and BOOTSTRAP
# ArgoCD's ownership of add-ons — not to own the add-ons. This file supersedes
# the minimal A2 (#174) seed and holds what stays Terraform-owned so ArgoCD can
# own everything else:
#
#   1. FACTS BRIDGE (epic #167 decision #3) — an in-cluster ArgoCD `cluster`
#      Secret whose annotations carry cluster identity (name, region) + the
#      lifecycle profile. Platform-addon ApplicationSets select it with a
#      `clusters` generator and inject the facts into their templates, so git
#      manifests stay cluster-agnostic (see gitops/platform-addons/addons/
#      alloy/application.yaml).
#   2. ROOT APP SEED — the app-of-apps root Application, shipped via the
#      argocd-apps chart. The SPEC's single source of truth is the committed
#      gitops/platform-addons/root-app.yaml (yamldecode — no second copy to
#      drift, A2's design kept); Terraform threads repoURL + targetRevision
#      over it (the A2 stub's TODO, now implemented).

# ── 1. Facts bridge ─────────────────────────────────────────────────────────
# In-cluster ArgoCD `cluster` Secret. server=https://kubernetes.default.svc is
# ArgoCD's in-cluster address: ArgoCD uses its own in-cluster rest config for it
# (the `config` blob is a minimal valid placeholder). Registering it explicitly
# is what lets a `clusters` generator attach to it and read its annotations.
resource "kubernetes_secret" "argocd_cluster_facts" {
  metadata {
    name      = "aegis-cluster-local"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      # A `clusters` generator selects on this label.
      "argocd.argoproj.io/secret-type" = "cluster"
    }
    annotations = {
      "aegis.binhsu.org/cluster-name" = local.cluster_name
      "aegis.binhsu.org/region"       = var.region
      # Lifecycle profile fact (epic #167 decision #6). Inert in A1 — A6 will
      # select add-on scope on it; written now so the bridge carries it from
      # day one.
      "aegis.binhsu.org/profile" = var.cluster_profile
    }
  }
  data = {
    name   = "in-cluster"
    server = "https://kubernetes.default.svc"
    config = jsonencode({ tlsClientConfig = { insecure = false } })
  }
  type = "Opaque"
}

# ── 2. Root app seed ────────────────────────────────────────────────────────
# Reuses the SAME CRD-safe delivery the workload ApplicationSet uses (the
# argocd-apps subchart — see argocd.tf for why kubernetes_manifest cannot apply
# an argoproj.io/Application at plan time). Single source of truth: the .spec
# block from the committed root-app.yaml; this seed reads it and overlays only
# the source coordinates Terraform knows better than a static file — the repo
# (from var.github_owner) and the revision (var.gitops_revision).
resource "helm_release" "platform_addons_root" {
  name       = "platform-addons-root"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.2" # pinned — same as helm_release.argocd_apps

  # B1 (2026-06-11): 600s so a busy bring-up does not deadline the 300s default.
  timeout = 600

  values = [yamlencode({
    applications = {
      # path.module is terraform/modules/regional-stack; the repo-root gitops/
      # tree is three up.
      platform-addons = merge(
        { namespace = "argocd" },
        yamldecode(file("${path.module}/../../../gitops/platform-addons/root-app.yaml")).spec,
        {
          source = merge(
            yamldecode(file("${path.module}/../../../gitops/platform-addons/root-app.yaml")).spec.source,
            {
              repoURL        = "https://github.com/${var.github_owner}/aegis-platform-aws"
              targetRevision = var.gitops_revision
            },
          )
        },
      )
    }
  })]

  # ArgoCD must exist (CRDs + repo-server) before the root Application lands;
  # the facts Secret must exist before children fan out from it.
  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_cluster_facts,
  ]
}
