# ACK IAM controller — AWS Controllers for Kubernetes, IAM service.
#
# This is the paved-road service that moves workload IAM out of the
# fabric/platform tier and into each deploy repo (ADR-07). A workload declares
# `Role`/`Policy` CRDs (iam.services.k8s.aws) at k8s/base/iam/*; this
# controller reconciles them into real AWS IAM. It sits alongside the ALB
# controller, external-dns, and Alloy as a platform-installed controller.
#
# Trust + permission seam:
#   - the controller SA (ack-system:ack-iam-controller) assumes the IRSA role
#     in irsa-ack-iam.tf (scoped to the /aegis-workload/ IAM path);
#   - that role's principal ARN is carved out of the fabric
#     `deny-iam-privilege-escalation` SCP, or `iam:CreateRole` is denied;
#   - Kyverno (kyverno.tf) rejects any workload `Role` CRD whose trust subject
#     names a namespace other than its own — cross-workload IAM-theft defense.
#
# ⚠️ implemented, E2E PENDING platform bootstrap — chart version pinned below
# is unverified against a live install; confirm at bootstrap (issue #6 gate:
# "ACK provisions the engine IAM role from the CRD").

resource "kubernetes_namespace" "ack_system" {
  metadata {
    name = "ack-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "helm_release" "ack_iam_controller" {
  # B1 (2026-06-11): the heavy platform controllers install in parallel and
  # deadline on the default 300s helm timeout during a busy cluster bring-up
  # ("context deadline exceeded"). 600s gives them room.
  timeout    = 600
  name       = "ack-iam-controller"
  namespace  = kubernetes_namespace.ack_system.metadata[0].name
  repository = "oci://public.ecr.aws/aws-controllers-k8s"
  chart      = "iam-chart"
  version    = "1.3.13" # pinned — verify at bootstrap

  set {
    name  = "aws.region"
    value = var.region
  }

  set {
    name  = "serviceAccount.name"
    value = "ack-iam-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_ack_iam.arn
  }

  depends_on = [module.eks]
}
