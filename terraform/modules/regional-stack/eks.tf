module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.cluster_name
  kubernetes_version = var.cluster_version

  endpoint_public_access = true
  enable_irsa            = true

  # Core addons — install the CNI BEFORE the node group joins (vpc-cni
  # before_compute=true) so it is initialised when nodes register and they come
  # up Ready. Without the addons map the EKS module installs NONE, so nodes stay
  # NotReady ("cni plugin not initialized") and every in-cluster helm_release
  # times out. (Surfaced live on the first prod regional apply — the running
  # cluster needed a manual `aws eks create-addon vpc-cni/kube-proxy/coredns`.)
  # NOTE: v21 renamed this from `cluster_addons` (v20) to `addons`.
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni = {
      before_compute = true
    }
    # EKS Pod Identity (ADR-21 §A). The agent DaemonSet intercepts the
    # workload's AWS SDK credential requests and serves short-lived creds for the
    # role bound to its ServiceAccount via aws_eks_pod_identity_association
    # (pod-identity-engine.tf). Without this add-on the association exists but no
    # pod ever receives credentials — the engine's `aws s3 sync` model-fetch
    # AccessDenies. This replaces the in-cluster Crossplane IRSA machinery the
    # engine used before (crossplane.tf / irsa-ack-iam.tf, retired this PR).
    eks-pod-identity-agent = {}
  }

  # All 5 control-plane log types → CloudWatch (audit / forensics
  # side-effect; never dashboarded). Per ADR-04 — CW retained
  # for audit only.
  enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]

  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # Managed node group on Spot — significant cost reduction; acceptable for
  # take-home + stateless workload (greeter has no in-flight session state).
  eks_managed_node_groups = {
    default = {
      # Graviton (arm64) node group. aegis-core engine/gateway publish arm64
      # images to GHCR (release-onprem-image.yml); the platform addon stack is
      # arm64-clean (verified: all helm charts + EKS addons multi-arch; the 3
      # digest/tag-pinned helpers — alpine/k8s, public.ecr.aws/aws-cli,
      # curlimages/curl — and the 3 Crossplane packages all resolve to
      # manifest-list images carrying linux/arm64). t4g is ~20% cheaper than t3.
      ami_type       = "AL2023_ARM_64_STANDARD"
      instance_types = [var.node_instance]
      capacity_type  = "SPOT"

      min_size     = var.node_min
      max_size     = var.node_max
      desired_size = var.node_min
    }
  }

  # OFF — this flag injects the *running caller's* ARN into access_entries,
  # which is identity-dependent: a local `make` run (IAM user) and a CI run
  # (the gh-tf-apply-platform role) compute different sets, causing drift,
  # and when CI runs as gh-tf-apply-platform it duplicates the explicit
  # infra_apply entry below → `CreateAccessEntry: ResourceInUse`. All cluster
  # access is the explicit, deterministic access_entries below — the human
  # operator included, so operator access does not depend on the (invisible,
  # creator-bound) EKS implicit grant and survives a recreate by any
  # principal.
  enable_cluster_creator_admin_permissions = false

  # Every principal that needs cluster access is listed explicitly — declared
  # ONCE in var.cluster_admin_principals (the env wires role outputs into it),
  # not as N copy-pasted blocks. A role missing from the map gets K8s
  # `Unauthorized` on every helm_release operation: that is exactly how the
  # destroy role stranded a billing cluster in the 2026-06-06 incident shape
  # (terraform destroy reaches helm_release.kyverno → Unauthorized → destroy
  # fails → cluster keeps billing). The CI roles read/manage Helm release
  # state (stored in K8s Secrets, which the EKS View policy cannot read) so
  # they all get ClusterAdmin; the AWS-side trust scoping (ci = read-only AWS
  # / any ref; apply = admin AWS / main + apply environments; destroy =
  # destroy/reaper-destroy environments) is the real blast-radius boundary.
  # Scaling this to a team of operators (IAM group / SSO-mapped entries) is
  # in tradeoffs.md.
  # null entries are dropped: the env passes null when a role's ARN is not
  # yet readable (e.g. a platform state that predates the output — see the
  # try() + check block in envs/regional/main.tf).
  access_entries = {
    for name, arn in var.cluster_admin_principals : name => {
      principal_arn = arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    } if arn != null
  }

  tags = local.common_tags
}

# Bound the EKS access-entry -> API-server authorizer propagation lag (WS4).
#
# The access_entries above (gh-tf-apply-platform -> AmazonEKSClusterAdminPolicy,
# the role this apply RUNS AS) are created in the same apply as the first
# cluster-scoped resource. CreateAccessEntry returning success does NOT mean the
# authorizer has the grant yet — there is a propagation lag. On run 27843245290
# the access entry completed at 19:03:36 and kubernetes_namespace.argocd started
# 1.3s later and failed "namespaces is forbidden" before the grant was effective.
# Terraform's existing depends_on=[module.eks] only waits for entry CREATION, not
# propagation, so it cannot close this race on its own.
#
# This is a bounded wait, not a band-aid: the access-entries design is correct
# (the executing role IS in cluster_admin_principals and gets ClusterAdmin); the
# only gap is timing. Every in-cluster resource that the apply role authors
# (namespaces, helm releases) depends_on this sleep instead of module.eks, so the
# first API call happens after the authorizer is consistent. 30s is the EKS
# guidance for access-entry propagation and matches the observed lag with margin.
resource "time_sleep" "eks_access_propagation" {
  depends_on      = [module.eks]
  create_duration = "30s"
}
