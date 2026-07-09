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
# ORDERING NOTE (the one behavioural change): the old release was in the
# `depends_on` of the workload ApplicationSet (argocd.tf :: helm_release
# .argocd_apps), which HARD-GATED the Rollout CRD to exist before any aegis-core
# Rollout was synced. That resource is gone, so that gate is gone. The workload
# ApplicationSet is still Terraform-owned in this A4 stopping point (A5 —
# migrating it to GitOps — is AWAITING BIN, epic #167 open-decision 5), and lives
# in a SEPARATE ArgoCD app tree, so cross-Application sync-waves do NOT span it.
# On first bring-up aegis-core can therefore briefly race ahead of the CRD and
# hit a TRANSIENT `Rollout.argoproj.io "" not found`; ArgoCD's automated retry +
# selfHeal converges once wave 0 lands the CRD. A5 restores the hard ordering by
# moving the workload ApplicationSet under the app-of-apps root at a wave after
# argo-rollouts. Tracked in the A4 PR (#176) as the note carried to A5.
#
# WHAT STAYED IN TERRAFORM: NOTHING from this file. Argo Rollouts uses no IRSA /
# EKS Pod Identity role in this module (contrast alb-controller / external-dns /
# pod-identity-*), so there is no ADR-22 identity boundary to keep behind. The
# cluster access-entries that let the controller run live in eks.tf, unaffected.
#
# REVERT: `git revert` restores the helm_release here (and its `depends_on` entry
# on the workload ApplicationSet in argocd.tf), and removes the GitOps
# Application. Single logical boundary.
