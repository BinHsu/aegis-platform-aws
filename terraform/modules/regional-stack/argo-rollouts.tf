# Argo Rollouts — the progressive-delivery controller the aegis-core workloads
# require. aegis-core-deploy ships the gateway and engine as
# `argoproj.io/v1alpha1` Rollouts (canary + ALB trafficRouting: a 50/50 soak
# before promotion), NOT plain Deployments. Without this controller the Rollout
# CRD does not exist, so the aegis-core ArgoCD Application fails to sync with
# `Rollout.argoproj.io "" not found` and the gateway/engine never come up
# (caught live 2026-06-18 on the first AWS staging bring-up of aegis-core).
#
# This is a cluster CAPABILITY, so it belongs in the platform tier next to the
# other addons (ArgoCD, kyverno, the ALB controller, Alloy) — the deploy repos
# carry only the workload `Rollout` resources, never the controller.
#
# ALB trafficRouting: the controller drives canary weight by managing the
# workload's ALB Ingress + TargetGroups, which the aws-load-balancer-controller
# (eks.tf addon) provisions. No extra Helm value is needed — the Rollout's
# `trafficRouting.alb` block references the Ingress and the controller's default
# RBAC already covers Ingress/Service edits.

resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  namespace        = "argo-rollouts"
  create_namespace = true
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  # Pinned — VERIFY against https://argoproj.github.io/argo-helm before the
  # bootstrap apply (same convention as kyverno.tf). Chart 2.37.x tracks
  # argo-rollouts v1.7.x; bump to the latest patch the apply environment
  # resolves. The next apply is operator-attended, so a stale pin surfaces as a
  # plan error, not a silent drift.
  version = "2.37.7"

  # CRDs install with the chart (the chart bundles crds/ and installs them by
  # default), so the Rollout CRD lands before the aegis-core sync that needs it.

  # Teardown safety — same posture as kyverno.tf (A4, 2026-06-06): wait=false so
  # a helm uninstall returns immediately rather than blocking `terraform
  # destroy` on controller/webhook deletion before it reaches the EKS cluster
  # delete (which would leave the cluster billing). The CRDs are applied
  # synchronously before the wait phase, so the controller is usable by the time
  # ArgoCD syncs aegis-core. timeout bounds any residual wait.
  wait    = false
  timeout = 300
}
