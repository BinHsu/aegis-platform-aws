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
      ami_type       = "AL2023_x86_64_STANDARD"
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
  access_entries = {
    for name, arn in var.cluster_admin_principals : name => {
      principal_arn = arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  tags = local.common_tags
}
