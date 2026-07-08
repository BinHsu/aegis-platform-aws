# Karpenter — node autoscaling (ADR-27, #182).
#
# WHY: no autoscaler was installed. The managed node group (MNG) pins
# desired_size to node_min and never moves it, so node_max was dead config and
# pending pods queued in `Pending` forever under load (the #182 failure
# scenario). ADR-27 chose Karpenter (option a) over Cluster Autoscaler / EKS
# Auto Mode / do-nothing: it is the AWS-recommended EKS autoscaler, provisions
# per pending-pod (no ASG coupling), bin-packs + consolidates (this repo's
# dominant constraint is cost), handles Spot interruption natively, and its
# capacity-type weighting subsumes the #183 static On-Demand baseline into a
# policy (spot-with-on-demand-fallback) instead of a second node group.
#
# DELIVERY: helm_release in this module, "same pattern as the existing
# controller set" (ADR-27 Decision (a)) — NOT a GitOps child app. This mirrors
# alb-controller.tf / argo-rollouts.tf / external-dns.tf. The default NodePool +
# EC2NodeClass ship as a LOCAL Helm chart (charts/karpenter-nodepool), the same
# CRD-safe delivery gitops-bootstrap.tf uses for argoproj.io/Application:
# kubernetes_manifest cannot apply a CRD instance at plan time (the CRD does not
# exist until the controller chart installs it), but a helm_release renders +
# applies at apply time, after the controller.
#
# CHICKEN-EGG (ADR-27 Against): Karpenter must run on nodes it does not manage.
# The existing MNG (eks.tf) is that static base — the Karpenter controller +
# system add-ons run there; Karpenter provisions everything else. The MNG stays
# as-is in this PR (still min/desired = node_min, max = node_max); ADR-27 stages
# the MNG shrink (node_min / node_max / #183 baseline cleanup) as a follow-up
# gated on Karpenter-provisioned capacity being verified on staging — see the PR
# body. This PR wires the scaler; it does not re-shape the static base.
#
# IAM: EKS Pod Identity (ADR-21 §A pattern) — the controller role trusts
# pods.eks.amazonaws.com and is bound to the karpenter ServiceAccount via a
# Pod Identity association the submodule creates (create_pod_identity_association
# = true), consistent with how the engine role is bound (pod-identity-engine.tf).
# No IRSA/OIDC authoring, no /aegis-workload/ path.
#
# ⚠️ VALIDATION PENDING ON A CLUSTER: real scale-out has NOT run against a live
# cluster. It is deferred to the single batched ephemeral-EKS validation run at
# the end of the optimization wave — see the PR body's checklist.

locals {
  # Fixed, region-suffixed node role name (IAM is account-global; two regions in
  # one account collide on a bare name — ADR-21 §C / #108 class). The EC2NodeClass
  # references this SAME name in its `role` field, so it is single-sourced here.
  karpenter_node_role_name = "aegis-karpenter-node-${var.region}"
}

# Controller IAM role + policy, node IAM role, SQS interruption queue +
# EventBridge rules (Spot 2-min notice / rebalance / instance health), the node
# EKS access entry, and the Pod Identity association. Reuses the canonical
# terraform-aws-modules/eks//modules/karpenter — the same module family as
# module.eks (eks.tf), versioned with it (~> 21.0), so no new provenance surface.
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.0"

  # Default on (ADR-27 "install ... behind a variable (default on)"). `create`
  # gates nearly all of the submodule's resources; its outputs fall back to null
  # when off, and the helm_releases below are count-gated on the same flag.
  create = var.enable_karpenter

  cluster_name = module.eks.cluster_name
  region       = var.region

  # Controller identity via EKS Pod Identity (ADR-21 §A / ADR-27).
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  # Region-suffixed FIXED names (no name_prefix) — the account-global IAM
  # collision guard the cold-start gate asserts (ADR-21 §C). Same fix shape as
  # the ALB controller role/policy (irsa-alb.tf) and the engine role.
  iam_role_use_name_prefix   = false
  iam_role_name              = "aegis-karpenter-controller-${var.region}"
  iam_policy_use_name_prefix = false
  iam_policy_name            = "aegis-karpenter-controller-${var.region}"

  node_iam_role_use_name_prefix = false
  node_iam_role_name            = local.karpenter_node_role_name
  # SSM access on Karpenter-launched nodes (Session Manager break-glass + AWS
  # guidance). The submodule already attaches AmazonEKSWorkerNodePolicy,
  # AmazonEC2ContainerRegistryPullOnly, and the CNI policy.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # SQS interruption queue (enable_spot_termination defaults true) — region-
  # suffixed for parity with the IAM names (SQS is regional, so this is for
  # readability, not a collision guard).
  queue_name = "aegis-karpenter-${var.region}"

  tags = local.common_tags
}

# Public ECR auth for the OCI Helm pull. public.ecr.aws serves anonymously but
# throttles unauthenticated pulls; an auth token avoids a throttled apply. AWS
# provider v6 takes a per-data-source `region` (ECR Public tokens are issued
# only from us-east-1), so no separate provider alias is needed.
data "aws_ecrpublic_authorization_token" "karpenter" {
  count  = var.enable_karpenter ? 1 : 0
  region = "us-east-1"
}

# Karpenter controller. Pinned (repo convention) — VERIFY against
# https://gallery.ecr.aws/karpenter/karpenter and the Karpenter/K8s
# compatibility matrix (https://karpenter.sh/docs/upgrading/compatibility/)
# before the operator-attended apply; a stale pin surfaces as a plan/apply
# error, not silent drift. v1.13.x supports K8s 1.30–1.36 (var.cluster_version
# default 1.35). Karpenter v1 chart bundles its CRDs (NodePool / EC2NodeClass /
# NodeClaim), so they exist before the karpenter-nodepool chart applies.
resource "helm_release" "karpenter" {
  count = var.enable_karpenter ? 1 : 0

  name                = "karpenter"
  namespace           = "kube-system"
  repository          = "oci://public.ecr.aws/karpenter"
  repository_username = data.aws_ecrpublic_authorization_token.karpenter[0].user_name
  repository_password = data.aws_ecrpublic_authorization_token.karpenter[0].password
  chart               = "karpenter"
  version             = "1.13.0" # pinned — see VERIFY note above

  # B1 (2026-06-11): 600s so a busy bring-up does not deadline the 300s default.
  timeout = 600

  # Teardown safety — same posture as kyverno.tf / argo-rollouts.tf (A4): wait
  # returns immediately so a `helm uninstall` cannot block `terraform destroy`
  # before it reaches the EKS cluster delete (the 2026-06-06 billing-cluster
  # shape). Karpenter's own controller is drained by the cluster delete.
  wait = false

  values = [yamlencode({
    settings = {
      clusterName       = module.eks.cluster_name
      clusterEndpoint   = module.eks.cluster_endpoint
      interruptionQueue = module.karpenter.queue_name
    }
    # Run the controller on the static MNG, never on a node it manages (the
    # chicken-egg constraint above). The MNG nodes carry no karpenter.sh/nodepool
    # label, so this affinity keeps the 2 controller replicas on the base.
    affinity = {
      nodeAffinity = {
        requiredDuringSchedulingIgnoredDuringExecution = {
          nodeSelectorTerms = [{
            matchExpressions = [{
              key      = "karpenter.sh/nodepool"
              operator = "DoesNotExist"
            }]
          }]
        }
      }
    }
    # The mutating/validating webhooks are off in v1 (conversion webhooks are
    # only needed mid-v1beta1→v1 migration; this is a fresh v1 install).
    webhook = { enabled = false }
  })]

  # Gate on the access-entry -> authorizer propagation (eks.tf, #185), same as
  # every other in-cluster helm_release. The submodule's IAM/SQS/associations
  # are AWS-side and independent, but the CHART lands in-cluster.
  depends_on = [terraform_data.eks_access_propagation]
}

# Default NodePool + EC2NodeClass (ADR-27: Graviton arm64, Spot-preferred with
# On-Demand fallback, consolidation enabled). Local chart = CRD-safe delivery
# (see file header). Applied after the controller chart installs the CRDs.
resource "helm_release" "karpenter_nodepool" {
  count = var.enable_karpenter ? 1 : 0

  name      = "karpenter-nodepool"
  namespace = "kube-system"
  chart     = "${path.module}/charts/karpenter-nodepool"

  timeout = 300

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    nodeRole    = local.karpenter_node_role_name
    cpuLimit    = var.karpenter_cpu_limit
    tags        = local.common_tags
  })]

  # CRDs must exist first (controller chart), and the authorizer must be live.
  depends_on = [
    helm_release.karpenter,
    terraform_data.eks_access_propagation,
  ]
}
