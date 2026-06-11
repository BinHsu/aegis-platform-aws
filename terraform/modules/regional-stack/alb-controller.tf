resource "helm_release" "alb_controller" {
  # B1 (2026-06-11): the heavy platform controllers install in parallel and
  # deadline on the default 300s helm timeout during a busy cluster bring-up
  # ("context deadline exceeded"). 600s gives them room.
  timeout    = 600
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.8.1" # pinned

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.irsa_alb_controller.arn
  }

  set {
    name  = "region"
    value = var.region
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  # ROOT-CAUSE FIX (2026-06-11): disable the Service mutating webhook.
  # The chart registers `mservice.elbv2.k8s.aws` (failurePolicy: Fail) on ALL
  # Service create/update. During the parallel platform bring-up the webhook is
  # registered BEFORE the controller pods are Ready → its backend has "no
  # endpoints available for service aws-load-balancer-webhook-service" → EVERY
  # Service creation cluster-wide fails, taking down crossplane/argocd/etc. with
  # `helm install` errors (the real cause of the staging-rehearsal apply failures,
  # not capacity/timeout). The Service mutator is only needed to manage
  # LoadBalancer-type Services via the controller; this stack exposes nothing that
  # way (greeter = Ingress/ALB, ArgoCD = ClusterIP), so disabling it is safe and
  # removes the bring-up deadlock at its source.
  set {
    name  = "enableServiceMutatorWebhook"
    value = "false"
  }

  depends_on = [module.eks]
}
