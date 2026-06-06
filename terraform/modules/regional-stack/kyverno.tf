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

  # A4: same destroy-hang mitigation as the kyverno release — deleting these
  # policy CRs on teardown can be blocked by kyverno's own webhook.
  wait    = false
  timeout = 300

  depends_on = [helm_release.kyverno]
}

# A4 root-cause fix (incident 2026-06-06). The teardown deadlock's source is
# kyverno's admission webhooks: during destroy the API server tries to reach the
# (terminating) kyverno backend, so deletions hang and the helm uninstall blocks.
# `wait = false` above stops terraform from blocking on it; this removes the
# webhook configurations BEFORE kyverno is uninstalled, breaking the deadlock at
# its source.
#
# depends_on => on DESTROY this null_resource is torn down FIRST (reverse order),
# so its destroy-time provisioner runs before helm uninstalls kyverno. Fully
# best-effort (set +e / exit 0): if kubectl or creds are absent it falls back to
# the wait=false behavior — it can never make a teardown worse, and never runs on
# apply (when = destroy). NOT yet live-verified; the planned teardown will.
resource "null_resource" "kyverno_webhook_predestroy_cleanup" {
  triggers = {
    cluster_name = local.cluster_name
    region       = var.region
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      set +e
      aws eks update-kubeconfig --name "${self.triggers.cluster_name}" --region "${self.triggers.region}" --kubeconfig "/tmp/kc-${self.triggers.cluster_name}" >/dev/null 2>&1 || exit 0
      export KUBECONFIG="/tmp/kc-${self.triggers.cluster_name}"
      for kind in validatingwebhookconfiguration mutatingwebhookconfiguration; do
        kubectl get "$kind" -o name 2>/dev/null | grep -i kyverno | while read -r n; do
          [ -n "$n" ] && kubectl delete "$n" --ignore-not-found --timeout=60s >/dev/null 2>&1
        done
      done
      exit 0
    EOT
  }

  depends_on = [helm_release.kyverno]
}
