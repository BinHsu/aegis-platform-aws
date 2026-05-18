module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.24"

  cluster_name    = local.cluster_name
  cluster_version = var.cluster_version

  cluster_endpoint_public_access = true
  enable_irsa                    = true

  # All 5 control-plane log types → CloudWatch (audit / forensics
  # side-effect; never dashboarded). Per ADR-04 — CW retained
  # for audit only.
  cluster_enabled_log_types = [
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
  # (the aegis-stateless-apply role) compute different sets, causing drift,
  # and when CI runs as aegis-stateless-apply it duplicates the explicit
  # infra_apply entry below → `CreateAccessEntry: ResourceInUse`. All cluster
  # access is the explicit, deterministic access_entries below — the human
  # operator included, so operator access does not depend on the (invisible,
  # creator-bound) EKS implicit grant and survives a recreate by any
  # principal.
  enable_cluster_creator_admin_permissions = false

  # Every principal that needs cluster access is listed explicitly. The CI
  # roles read/manage Helm release state (stored in K8s Secrets, which the
  # EKS View policy cannot read) so they get ClusterAdmin; the AWS-side
  # trust scoping (ci = read-only AWS / any ref; apply = admin AWS /
  # refs/heads/main) is the real blast-radius boundary. Scaling this to a
  # team of operators (IAM group / SSO-mapped entries) is in tradeoffs.md.
  access_entries = {
    operator = {
      principal_arn = var.operator_principal_arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    infra_ci = {
      principal_arn = var.ci_role_arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    infra_apply = {
      principal_arn = var.apply_role_arn
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
