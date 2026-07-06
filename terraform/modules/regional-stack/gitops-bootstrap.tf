# GitOps app-of-apps bootstrap — MINIMAL A2 SEAM (epic #167 / issue #174).
#
# ─────────────────────────────────────────────────────────────────────────────
# ⚠️  This is the SMALLEST Terraform seed A2 needs, created because A1 (#173) —
#     which OWNS the GitOps bootstrap + cluster-facts bridge — is not yet
#     implemented. A2 removed helm_release.kyverno / helm_release.aegis_policies
#     (kyverno.tf) and delivers them through ArgoCD instead; SOMETHING has to
#     seed the app-of-apps root so the EKS path is not left without Kyverno.
#
#     A1 MUST reconcile this file:
#       - fold this seed into A1's ArgoCD bootstrap (root Application + the
#         Terraform-written cluster-facts Secret, epic decision #3);
#       - thread repoURL + targetRevision from cluster facts so root-app.yaml
#         stops hardcoding the public repo + `main` (see its TODO).
#     Until then, keep this seed tiny and self-contained.
# ─────────────────────────────────────────────────────────────────────────────
#
# HOW: reuses the SAME CRD-safe delivery the workload ApplicationSet uses (the
# argocd-apps subchart — see argocd.tf for why kubernetes_manifest cannot apply
# an argoproj.io/Application at plan time). The root Application SPEC is the
# single source of truth in gitops/platform-addons/root-app.yaml; this seed just
# reads it and hands it to the chart, so there is no second copy to drift.
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
      # Single source of truth: the .spec block from the committed root-app.yaml,
      # so this seed cannot diverge from the git-native manifest. path.module is
      # terraform/modules/regional-stack; the repo-root gitops/ tree is three up.
      platform-addons = merge(
        { namespace = "argocd" },
        yamldecode(file("${path.module}/../../../gitops/platform-addons/root-app.yaml")).spec,
      )
    }
  })]

  # ArgoCD must exist (CRDs + repo-server) before the root Application lands.
  depends_on = [helm_release.argocd]
}
