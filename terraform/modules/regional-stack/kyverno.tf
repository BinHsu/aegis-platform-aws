# Kyverno — policy engine carrying two of the enforcement four-pack guardrails
# that make workload self-ownership safe (ADR-07):
#
#   #2 cross-workload IAM-theft defense — a ClusterPolicy rejects any ACK
#      `Role` CRD whose trust subject names a ServiceAccount in a namespace
#      other than the CRD's own. aegis-greeter's deploy repo physically cannot
#      declare a role that trusts system:serviceaccount:aegis-core:...
#   #4 NetworkPolicy default-deny baseline — a generate ClusterPolicy stamps a
#      default-deny NetworkPolicy into every `aegis-*` namespace at creation.
#      This is the "ldz #54 platform contract" the deploy repos' manifests
#      already ASSUME (they layer allow-rules on top) but which was never
#      actually built — the namespace is open today. This builds it.
#
# (#1 AppProject + ApplicationSet namespace-derivation lives in argocd.tf;
# #3 the org SCP lives in the fabric repo. Kyverno also enforces the PSS
# `restricted` floor per ADR-06, configured via the chart defaults below.)
#
# The policies ship as a small in-repo Helm chart (charts/aegis-policies)
# rather than `kubernetes_manifest` — Kyverno's CRDs do not exist at plan time,
# which `kubernetes_manifest` cannot tolerate; a Helm release renders
# client-side and applies after the CRDs land. Same reason argocd.tf uses the
# argocd-apps chart for the ApplicationSet/AppProject.
#
# ⚠️ implemented, E2E PENDING platform bootstrap — the negative tests in the
# issue #6 gate (Kyverno rejects a mismatched trust-subject; default-deny
# actually denies) have NOT run against a live cluster.

resource "helm_release" "kyverno" {
  name             = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  version          = "3.2.6" # pinned — verify at bootstrap

  # A4 (incident 2026-06-06): kyverno's admission webhooks + finalizers deadlock
  # the helm uninstall, which with the default wait=true blocked `terraform
  # destroy` for 5 min before it reached aws_eks_cluster — leaving the cluster
  # billing. wait=false makes uninstall return without waiting for the
  # webhook-blocked deletion, so destroy proceeds to delete the cluster (which
  # takes kyverno with it). timeout bounds any residual wait. The apply-time
  # readiness hang was a separate root cause (NotReady nodes), already fixed by
  # the CNI addons in eks.tf (#20). Trade-off: apply no longer blocks on kyverno
  # being Ready — acceptable here (policies are Audit-mode; CRDs are still
  # applied synchronously before the wait phase, so aegis_policies ordering
  # holds). NOT yet live-verified on a real teardown.
  wait    = false
  timeout = 300

  # Bitnami pulled bitnami/kubectl from free Docker Hub access on 2025-08-28.
  # Caught live 2026-06-11 as ImagePullBackOff on all kyverno cleanup pods
  # (kyverno-cleanup-admission-reports-*, kyverno-cleanup-cluster-admission-
  # reports-*, kyverno-cleanup-cluster-ephemeral-reports-*, kyverno-cleanup-
  # ephemeral-reports-*, kyverno-cleanup-update-requests-*,
  # kyverno-remove-configmap-*). The upstream-maintained replacement is
  # registry.k8s.io/kubectl (same binary, no auth wall).
  #
  # All 7 value paths confirmed from `helm show values kyverno/kyverno --version
  # 3.2.6` (every path that held `repository: bitnami/kubectl`):
  #   webhooksCleanup.image.*
  #   policyReportsCleanup.image.*
  #   cleanupJobs.admissionReports.image.*
  #   cleanupJobs.clusterAdmissionReports.image.*
  #   cleanupJobs.updateRequests.image.*
  #   cleanupJobs.ephemeralReports.image.*
  #   cleanupJobs.clusterEphemeralReports.image.*
  values = [yamlencode({
    webhooksCleanup = {
      image = {
        registry   = "registry.k8s.io"
        repository = "kubectl"
        tag        = "v1.31.0"
      }
    }
    policyReportsCleanup = {
      image = {
        registry   = "registry.k8s.io"
        repository = "kubectl"
        tag        = "v1.31.0"
      }
    }
    cleanupJobs = {
      admissionReports = {
        image = {
          registry   = "registry.k8s.io"
          repository = "kubectl"
          tag        = "v1.31.0"
        }
      }
      clusterAdmissionReports = {
        image = {
          registry   = "registry.k8s.io"
          repository = "kubectl"
          tag        = "v1.31.0"
        }
      }
      updateRequests = {
        image = {
          registry   = "registry.k8s.io"
          repository = "kubectl"
          tag        = "v1.31.0"
        }
      }
      ephemeralReports = {
        image = {
          registry   = "registry.k8s.io"
          repository = "kubectl"
          tag        = "v1.31.0"
        }
      }
      clusterEphemeralReports = {
        image = {
          registry   = "registry.k8s.io"
          repository = "kubectl"
          tag        = "v1.31.0"
        }
      }
    }
  })]

  depends_on = [module.eks]
}

# The aegis policy set — separate release so a policy change has a tighter
# blast radius than reinstalling the Kyverno controller.
resource "helm_release" "aegis_policies" {
  name      = "aegis-policies"
  namespace = helm_release.kyverno.namespace
  chart     = "${path.module}/charts/aegis-policies"

  # The workload-namespace prefix the default-deny generate policy targets is
  # the only knob; everything else is static policy text.
  set {
    name  = "workloadNamespaceGlob"
    value = "aegis-*"
  }

  # ADR-10 require-digest policy enforcement action. Default "Audit" — the
  # policy logs tag-only images but admits them, so landing it cannot wedge a
  # workload that has not yet migrated to digest pinning (ADR-10 phase 3). Flip
  # to "Enforce" via var.require_digest_action AFTER the deploy repos pin
  # @sha256 and an Audit run shows zero violations.
  set {
    name  = "requireDigestAction"
    value = var.require_digest_action
  }

  # A4: same destroy-hang mitigation as the kyverno release — deleting these
  # policy CRs on teardown can be blocked by kyverno's own webhook.
  wait    = false
  timeout = 300

  depends_on = [helm_release.kyverno]
}

# A4 teardown deadlock — root cause + fix (incident 2026-06-06).
#
# Root cause: kyverno's admission webhooks are fail-closed AND its CRs carry
# finalizers. On a graceful helm uninstall the API server tries to reach the
# (terminating) kyverno backend → deletions hang on "no endpoints available",
# and finalizer-bearing CRs never finish deleting → the uninstall blocks. This
# is generic to every admission-webhook operator, not kyverno-specific.
#
# The previous attempt here was an in-module `null_resource` destroy provisioner
# that kubectl-deleted the webhook configs first. It was REMOVED 2026-06-11: it
# was inert (the infra-ops runner has no kubectl, so it no-op'd on its first live
# test) and it never addressed finalizers.
#
# Real fix (industry norm for EPHEMERAL clusters): do NOT graceful-uninstall —
# delete the cluster and let it reap the in-cluster charts. The teardown
# (`.github/workflows/infra-ops.yml` destroy-region) now `terraform state rm`s
# every helm_release/kubernetes_ resource before `terraform destroy`, so the
# deadlock-prone uninstall is never attempted. `wait = false` + `timeout = 300`
# above remain as belt-and-suspenders for any non-ephemeral path.
