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

  # Karpenter (ADR-27 / karpenter.tf) discovers the node security group by this
  # tag — the EC2NodeClass securityGroupSelectorTerms match karpenter.sh/discovery
  # = <cluster>. Empty when Karpenter is off (a plain tag is harmless either way).
  # Subnets are discovered via the tags vpc.tf already sets, so only the node SG
  # needs this extra tag.
  node_security_group_tags = var.enable_karpenter ? {
    "karpenter.sh/discovery" = local.cluster_name
  } : {}

  # Managed node group on Spot — significant cost reduction; acceptable for
  # take-home + stateless workload (greeter has no in-flight session state).
  #
  # #183: single-instance-type all-Spot is a reclaim-the-whole-group
  # anti-pattern — one AWS-wide Spot pool reclamation can take every node down
  # at once, with only the 2-minute interruption notice. Two mitigations:
  #   1. var.node_instance_types lists >=2 families (diversification below) so
  #      the EKS module's EC2 Fleet spreads allocation across independent
  #      Spot pools.
  #   2. var.node_ondemand_baseline (>0 for prod) adds a small On-Demand node
  #      group alongside the Spot one, so a Spot-wide reclamation cannot take
  #      the cluster to zero nodes.
  eks_managed_node_groups = merge(
    {
      default = {
        # Graviton (arm64) node group. aegis-core engine/gateway publish arm64
        # images to GHCR (release-onprem-image.yml); the platform addon stack
        # is arm64-clean (verified: all helm charts + EKS addons multi-arch;
        # the 3 digest/tag-pinned helpers — alpine/k8s,
        # public.ecr.aws/aws-cli, curlimages/curl — and the 3 Crossplane
        # packages all resolve to manifest-list images carrying linux/arm64).
        # t4g is ~20% cheaper than t3.
        ami_type       = "AL2023_ARM_64_STANDARD"
        instance_types = var.node_instance_types
        capacity_type  = "SPOT"

        min_size     = var.node_min
        max_size     = var.node_max
        desired_size = var.node_min
      }
    },
    # On-Demand baseline — a separate managed node group (EKS managed node
    # groups are single-capacity-type; Spot + On-Demand cannot mix inside
    # one group). Only created when var.node_ondemand_baseline > 0 (prod);
    # an empty map here means no resource at all, not a 0/0/0 no-op group.
    var.node_ondemand_baseline > 0 ? {
      on_demand_baseline = {
        ami_type       = "AL2023_ARM_64_STANDARD"
        instance_types = var.node_instance_types
        capacity_type  = "ON_DEMAND"

        min_size     = var.node_ondemand_baseline
        max_size     = var.node_ondemand_baseline
        desired_size = var.node_ondemand_baseline
      }
    } : {}
  )

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
  # (terraform destroy reaches a TF-owned helm_release — historically
  # kyverno, now the ArgoCD bootstrap + remaining add-ons — → Unauthorized →
  # destroy fails → cluster keeps billing). The CI roles read/manage Helm release
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

# Wait out the EKS access-entry -> API-server authorizer propagation lag (WS4)
# by POLLING the actual condition, not sleeping a guessed duration (#185).
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
# HISTORY (#185): this was a fixed 30s `time_sleep` — wrong in both directions:
# too short under control-plane / IAM propagation load (the race resurfaces as
# a flaky apply), pure waste on every normal apply. Replaced with the canonical
# eventual-consistency wait: poll a SelfSubjectAccessReview (`kubectl auth
# can-i`, executed AS the applying principal via a freshly-written kubeconfig)
# until the authorizer actually serves the grant. Bounded at 120s (24 x 5s;
# observed lag is seconds — 30s was the guidance ceiling, 120s adds margin for
# the loaded case the fixed sleep could not cover). The fast path exits on the
# first successful attempt instead of always burning 30s. Every in-cluster
# resource the apply role authors (namespaces, helm releases) depends_on this
# gate instead of module.eks, so the first real API call happens after the
# authorizer is consistent.
#
# Provisioner requirements: aws CLI + kubectl on the applying host — both are
# repo minimum requirements (CONTRIBUTING.md) and preinstalled on the GitHub
# ubuntu runners. Provisioners run at APPLY only, so read-only plans (the
# version gate, infra-plan under the ReadOnlyAccess CI role) never execute
# this, and the mock-provider cold-start tftest is unaffected.
resource "terraform_data" "eks_access_propagation" {
  depends_on = [module.eks]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      KUBECONFIG_TMP="$(mktemp)"
      trap 'rm -f "$KUBECONFIG_TMP"' EXIT
      aws eks update-kubeconfig \
        --name "${local.cluster_name}" \
        --region "${var.region}" \
        --kubeconfig "$KUBECONFIG_TMP" >/dev/null
      for i in $(seq 1 24); do
        # SelfSubjectAccessReview as the applying principal: succeeds only
        # once the access-entry grant is live in the cluster authorizer.
        if kubectl --kubeconfig "$KUBECONFIG_TMP" auth can-i create namespace >/dev/null 2>&1; then
          echo "EKS access entry propagated (attempt $i)."
          exit 0
        fi
        echo "waiting for EKS access-entry propagation (attempt $i/24)..."
        sleep 5
      done
      echo "ERROR: EKS access entry did not propagate within 120s — authorizer still denies the applying principal." >&2
      exit 1
    EOT
  }
}
