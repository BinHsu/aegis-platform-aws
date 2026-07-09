# Argo Rollouts — MIGRATED TO GITOPS (epic #167 A4 / issue #176).
#
# ─────────────────────────────────────────────────────────────────────────────
# This file previously held one helm_release resource:
#   - helm_release.argo_rollouts   (the progressive-delivery controller + CRDs)
# ADR-25 ownership inversion moved it out of Terraform and into ArgoCD:
#   - gitops/platform-addons/addons/argo-rollouts/application.yaml   (sync-wave 0)
# The app-of-apps root that delivers it: gitops/platform-addons/root-app.yaml,
# seeded from Terraform in gitops-bootstrap.tf (the A1 #173 facts-bridge
# bootstrap). It needs NO facts bridge — the controller took zero account-bound
# values (no `set` blocks on the old release), so it is a plain Application (like
# kyverno), not an ApplicationSet.
#
# WHY: Terraform owning this in-cluster object is the ownership mismatch epic
# #167 dissolves — one more add-on off Terraform state, so `terraform destroy`
# no longer helm-uninstalls it (the cluster delete reaps it). The old
# wait=false + timeout=300 teardown posture is preserved structurally in the
# Application (no resources-finalizer → no foreground cascade on Application
# deletion). See the Application header.
#
# WHAT MOVED WHERE:
#   - chart pin (argo-rollouts 2.37.7)     → argo-rollouts Application source.targetRevision
#   - namespace argo-rollouts + create     → destination.namespace + syncOptions CreateNamespace=true
#   - CRD install (chart installCRDs=true) → ArgoCD renders the CRDs from the
#                                            chart templates (ServerSideApply=true
#                                            — the argoproj.io CRDs exceed the
#                                            256 KB client-side annotation limit)
#   - ordering (Rollout CRD before the      → sync-wave 0, ahead of later waves in
#     workload sync)                          the app-of-apps. See ORDERING NOTE.
#
# ORDERING NOTE: the old release was in the `depends_on` of the workload
# ApplicationSet (argocd.tf :: helm_release.argocd_apps), which HARD-GATED the
# Rollout CRD to exist before any aegis-core Rollout was synced. A4 removed that
# resource, dropping the gate and opening a transient race window
# (`Rollout.argoproj.io "" not found`). A5 (epic #167 / issue #177) CLOSED it: the
# workload ApplicationSet moved to GitOps under the SAME app-of-apps root
# (gitops/platform-addons/addons/workloads/) at a wave AFTER argo-rollouts (wave 0),
# with a retry block on the generated Application as the convergence backstop. The
# cross-tree gap this note used to describe no longer exists.
#
# WHAT STAYED IN TERRAFORM: NOTHING from this file. Argo Rollouts uses no IRSA /
# EKS Pod Identity role in this module (contrast alb-controller / external-dns /
# pod-identity-*), so there is no ADR-22 identity boundary to keep behind. The
# cluster access-entries that let the controller run live in eks.tf, unaffected.
#
# REVERT: `git revert` restores the helm_release here (and its `depends_on` entry
# on the workload ApplicationSet in argocd.tf), and removes the GitOps
# Application. Single logical boundary.
