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

  # Kyverno 3.2.6's cleanup cronjobs default to docker.io/bitnami/kubectl:1.28.5,
  # which Bitnami removed from Docker Hub (2025 catalog deprecation) -> the cleanup
  # pods ImagePullBackOff on a fresh deploy. Repoint to Bitnami's legacy archive of
  # the same image. (Durable follow-up: bump the kyverno chart to a release that
  # uses a maintained kubectl image.) Surfaced on the first prod regional apply.
  values = [yamlencode({
    cleanupJobs = {
      admissionReports        = { image = { repository = "bitnamilegacy/kubectl" } }
      clusterAdmissionReports = { image = { repository = "bitnamilegacy/kubectl" } }
      ephemeralReports        = { image = { repository = "bitnamilegacy/kubectl" } }
      clusterEphemeralReports = { image = { repository = "bitnamilegacy/kubectl" } }
      updateRequests          = { image = { repository = "bitnamilegacy/kubectl" } }
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

  depends_on = [helm_release.kyverno]
}
