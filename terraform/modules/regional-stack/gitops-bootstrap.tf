# GitOps bootstrap + facts bridge (ADR-25 ownership inversion, epic #167, A1).
#
# Terraform's job after the inversion is to own the CLUSTER and BOOTSTRAP
# ArgoCD's ownership of add-ons — not to own the add-ons. This file supersedes
# the minimal A2 (#174) seed and holds what stays Terraform-owned so ArgoCD can
# own everything else:
#
#   1. FACTS BRIDGE (epic #167 decision #3) — an in-cluster ArgoCD `cluster`
#      Secret whose annotations carry cluster identity (name, region) + the
#      lifecycle profile. Platform-addon ApplicationSets select it with a
#      `clusters` generator and inject the facts into their templates, so git
#      manifests stay cluster-agnostic (see gitops/platform-addons/addons/
#      alloy/application.yaml).
#   2. ROOT APP SEED — the app-of-apps root Application, shipped via the
#      argocd-apps chart. The SPEC's single source of truth is the committed
#      gitops/platform-addons/root-app.yaml (yamldecode — no second copy to
#      drift, A2's design kept); Terraform threads repoURL + targetRevision
#      over it (the A2 stub's TODO, now implemented).
#   3. CREDS BRIDGE (epic #167 decision #4) — the monitoring namespace + the
#      Grafana Cloud credentials Secret. Creds are TF-written and referenced
#      from git by name (envFrom), never stored in git. Pre-migration ownership
#      (helm_release.alloy / node_exporter / kube_state_metrics in alloy.tf) is
#      now GitOps: gitops/platform-addons/addons/alloy/.

# ── 1. Facts bridge ─────────────────────────────────────────────────────────
# In-cluster ArgoCD `cluster` Secret. server=https://kubernetes.default.svc is
# ArgoCD's in-cluster address: ArgoCD uses its own in-cluster rest config for it
# (the `config` blob is a minimal valid placeholder). Registering it explicitly
# is what lets a `clusters` generator attach to it and read its annotations.
resource "kubernetes_secret" "argocd_cluster_facts" {
  metadata {
    name      = "aegis-cluster-local"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      # A `clusters` generator selects on this label.
      "argocd.argoproj.io/secret-type" = "cluster"
      # Fan-out GATE for the observability add-ons (addons/alloy/*): "true"
      # only when this same apply also wrote their prerequisites (monitoring
      # namespace + grafana-cloud-credentials Secret). Labels, not annotations,
      # because clusters-generator selectors match labels.
      "aegis.binhsu.org/observability" = var.enable_observability ? "true" : "false"
      # Profile GATE for the profile-scoped add-ons (A6 / #178): the ALB
      # controller + external-dns ApplicationSets (gitops/platform-addons/addons/
      # alb-controller, .../external-dns) select clusters whose profile is "full",
      # so an EPHEMERAL cluster installs NEITHER. Those two are the only add-ons
      # that create AWS objects OUTSIDE Terraform state (ALBs, controller-owned
      # SGs, Route53 records) — the exact objects the bespoke teardown machinery
      # existed to reap. Gating them to full means an ephemeral teardown collapses
      # to a plain `terraform destroy` (epic #167 target end-state). Mirrored from
      # the /profile ANNOTATION below (same var) because clusters-generator
      # selectors match LABELS, not annotations — the observability idiom above.
      "aegis.binhsu.org/profile" = var.cluster_profile
    }
    annotations = {
      "aegis.binhsu.org/cluster-name" = local.cluster_name
      "aegis.binhsu.org/region"       = var.region
      # Account-bound fact (epic #167 A3 / #175). The Crossplane definitions
      # ApplicationSet (gitops/platform-addons/addons/crossplane/
      # applicationset-definitions.yaml) reads this to render the deterministic
      # workload-bucket name "<prefix>-<name>-<account>-<region>" — the value MUST
      # match the account Terraform ran in, because crossplane.tf's provider IAM
      # policy is scoped to that exact prefix. Kept off git (cluster-agnostic
      # manifests, the A1 facts-bridge rule); surfaced to the ApplicationSet
      # template via the clusters generator.
      "aegis.binhsu.org/account-id" = data.aws_caller_identity.current.account_id
      # Lifecycle profile fact (epic #167 decision #6). CONSUMED as of A6 (#178):
      # the add-on scope selector is the /profile LABEL above (selectors match
      # labels); this annotation stays as the human-readable / greppable copy of
      # the same var.cluster_profile value.
      "aegis.binhsu.org/profile" = var.cluster_profile
      # ── ALB controller + external-dns facts (A6 / #178) ──────────────────────
      # These two add-ons moved from Terraform helm_release to GitOps-owned
      # ApplicationSets gated to profile=full (gitops/platform-addons/addons/
      # alb-controller, .../external-dns). Their charts need account/cluster-bound
      # values that must NOT be hardcoded in the public git manifest (the same
      # cluster-agnostic rule A1 set for Alloy's cluster-name/region). Surfaced
      # here for the clusters generator to inject verbatim into the chart values —
      # a byte-for-byte port of the `set` blocks the old helm_releases carried.
      "aegis.binhsu.org/vpc-id"                = module.vpc.vpc_id
      "aegis.binhsu.org/alb-role-arn"          = module.irsa_alb_controller.arn
      "aegis.binhsu.org/external-dns-role-arn" = module.irsa_external_dns.arn
      # external-dns domainFilter — the platform-owned zone, trailing dot trimmed
      # (identical to the old external-dns.tf `domainFilters[0]` set).
      "aegis.binhsu.org/zone-name" = trimsuffix(var.zone_name, ".")
      # Workload catalog (epic #167 A5 / issue #177). Terraform still builds the
      # per-workload element list from registries.auto.tfvars.json + AWS resources
      # (argocd.tf :: local.workload_list_elements — registries.auto.tfvars.json
      # stays the source of truth, epic decision #4), but instead of interpolating
      # it into an inline Helm List generator it writes it HERE as one JSON
      # annotation. The git workload ApplicationSet
      # (gitops/platform-addons/addons/workloads/applicationset.yaml) reads it back
      # with a Matrix(clusters × list.elementsYaml) generator, so the git manifest
      # stays cluster-agnostic (no account IDs / cert ARNs in the public repo — the
      # D4 account-ID-hide rule) and the rendered Application is byte-identical to
      # the old TF-templated form. Empty map => "[]" (no workloads) is valid and
      # generates zero Applications. Well under the 256 KB per-object annotation
      # limit for any realistic catalog.
      "aegis.binhsu.org/workloads" = jsonencode(local.workload_list_elements)
    }
  }
  data = {
    name   = "in-cluster"
    server = "https://kubernetes.default.svc"
    config = jsonencode({ tlsClientConfig = { insecure = false } })
  }
  type = "Opaque"
}

# ── 2. Root app seed ────────────────────────────────────────────────────────
# Reuses the SAME CRD-safe delivery the workload ApplicationSet uses (the
# argocd-apps subchart — see argocd.tf for why kubernetes_manifest cannot apply
# an argoproj.io/Application at plan time). Single source of truth: the .spec
# block from the committed root-app.yaml; this seed reads it and overlays only
# the source coordinates Terraform knows better than a static file — the repo
# (from var.github_owner) and the revision (var.gitops_revision).
resource "helm_release" "platform_addons_root" {
  name       = "platform-addons-root"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.2" # pinned — same as helm_release.argocd_apps

  # B1 (2026-06-11): 600s so a busy bring-up does not deadline the 300s default.
  timeout = 600

  values = [yamlencode({
    applications = {
      # path.module is terraform/modules/regional-stack; the repo-root gitops/
      # tree is three up.
      platform-addons = merge(
        { namespace = "argocd" },
        yamldecode(file("${path.module}/../../../gitops/platform-addons/root-app.yaml")).spec,
        {
          source = merge(
            yamldecode(file("${path.module}/../../../gitops/platform-addons/root-app.yaml")).spec.source,
            {
              repoURL        = "https://github.com/${var.github_owner}/aegis-platform-aws"
              targetRevision = var.gitops_revision
            },
          )
        },
      )
    }
  })]

  # ArgoCD must exist (CRDs + repo-server) before the root Application lands;
  # the facts Secret must exist before children fan out from it.
  depends_on = [
    helm_release.argocd,
    kubernetes_secret.argocd_cluster_facts,
  ]
}

# ── 3. Creds bridge (observability) ─────────────────────────────────────────
# Migrated verbatim from alloy.tf. Gated on enable_observability so a bare /
# observability-free module applies cleanly (the gc_* vars are only consumed
# here). The Alloy ApplicationSet references the Secret by name via envFrom.
resource "kubernetes_namespace" "monitoring" {
  count = var.enable_observability ? 1 : 0

  # Wait for the EKS access-entry -> authorizer propagation (eks.tf) before the
  # first cluster-scoped create — same gate the argocd namespace uses
  # (terraform_data active-poll since #185; was a fixed time_sleep).
  depends_on = [terraform_data.eks_access_propagation]

  metadata {
    name = "monitoring"
    labels = {
      # Alloy + node-exporter use hostPath / hostNetwork and read kubelet
      # metrics, so the namespace runs `privileged` PSS — not the restricted
      # profile applied to the workload ns. ArgoCD CreateNamespace cannot set
      # these labels, which is one reason the namespace stays Terraform-owned.
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

# K8s Secret holding Grafana Cloud credentials (epic #167 D4). TF reads SSM at
# the regional env scope and passes values in as sensitive module vars; the
# Alloy DaemonSet mounts these as env vars (envFrom.secretRef) and the River
# config reads them as sys.env("API_TOKEN") etc.
resource "kubernetes_secret" "grafana_cloud" {
  count = var.enable_observability ? 1 : 0

  metadata {
    name      = "grafana-cloud-credentials"
    namespace = kubernetes_namespace.monitoring[0].metadata[0].name
  }

  # Keys are UPPERCASE — `envFrom.secretRef` maps each key verbatim to an env
  # var, and the Alloy River config reads them via sys.env("API_TOKEN") etc.
  # Lowercase keys here would silently not match.
  data = {
    API_TOKEN          = var.gc_api_token
    MIMIR_URL          = var.gc_mimir_url
    MIMIR_USERNAME     = var.gc_mimir_username
    LOKI_URL           = var.gc_loki_url
    LOKI_USERNAME      = var.gc_loki_username
    TEMPO_URL          = var.gc_tempo_url
    TEMPO_USERNAME     = var.gc_tempo_username
    PYROSCOPE_URL      = var.gc_pyroscope_url
    PYROSCOPE_USERNAME = var.gc_pyroscope_username
  }

  type = "Opaque"
}
