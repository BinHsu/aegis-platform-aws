# Kyverno + aegis-policies — MIGRATED TO GITOPS (epic #167 A2 / issue #174).
#
# ─────────────────────────────────────────────────────────────────────────────
# This file previously held two helm_release resources:
#   - helm_release.kyverno         (the policy-engine controller + CRDs)
#   - helm_release.aegis_policies  (the ADR-07 #4 default-deny + ADR-10
#                                   require-digest ClusterPolicies)
# ADR-25 ownership inversion moved BOTH out of Terraform and into ArgoCD:
#   - gitops/platform-addons/addons/kyverno/application.yaml         (sync-wave 0)
#   - gitops/platform-addons/addons/aegis-policies/application.yaml  (sync-wave 1)
# The app-of-apps root that delivers them: gitops/platform-addons/root-app.yaml,
# seeded from Terraform in gitops-bootstrap.tf (a MINIMAL A2 seam — A1 #173
# reconciles it into the proper facts-bridge bootstrap).
#
# WHY: Terraform owning these in-cluster objects is exactly the ownership
# mismatch epic #167 dissolves. Kyverno's fail-closed admission webhooks +
# finalizer-bearing CRs deadlocked `helm uninstall`, which blocked `terraform
# destroy` before it reached aws_eks_cluster — the 2026-06-06 billing incident.
# The old mitigation (wait=false + timeout=300 on both releases) papered over the
# symptom; GitOps ownership fixes the root cause: `terraform destroy` no longer
# uninstalls Kyverno at all — the cluster delete reaps it. The wait=false intent
# is preserved structurally in the Applications (no resources-finalizer → no
# foreground cascade on Application deletion). See each Application's header.
#
# WHAT MOVED WHERE:
#   - chart pin (kyverno 3.2.6)            → kyverno Application source.targetRevision
#   - cleanup-image overrides (7 paths,    → kyverno Application spec.source.helm.values
#     alpine/k8s:1.31.13 + UID 65534)
#   - workloadNamespaceGlob = "aegis-*"    → aegis-policies Application helm.values
#   - requireDigestAction (was            → aegis-policies Application helm.values
#     var.require_digest_action, Audit)      (Audit default; var removed as dead code)
#   - depends_on (CRDs before policies)    → ArgoCD sync-waves 0 → 1
#   - CreateNamespace                      → syncPolicy.syncOptions CreateNamespace=true
#
# WHAT STAYED IN TERRAFORM: NOTHING from this file. Kyverno uses no IRSA / EKS
# Pod Identity role in this module (contrast alb-controller / external-dns /
# pod-identity-*), so there is no ADR-22 identity boundary to keep behind. The
# cluster access-entries that let the controllers run at all live in eks.tf and
# are unaffected.
#
# REVERT: `git revert` restores both helm_release resources (and
# var.require_digest_action) here, and removes the GitOps Applications +
# gitops-bootstrap.tf. Single logical boundary.
#
# PATTERN FOR A3–A6 (#175–#178): each remaining add-on follows this exact shape —
# add gitops/platform-addons/addons/<name>/application.yaml (with a sync-wave and,
# for any webhook/finalizer operator, NO resources-finalizer), delete its
# helm_release here, and move its TF-only knobs into the Application's helm.values.
# Keep any IRSA/Pod-Identity role in Terraform (ADR-22) — only the helm_release moves.
