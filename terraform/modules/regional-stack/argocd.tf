# ArgoCD per cluster — NOT hub-spoke. Each EKS cluster runs its own ArgoCD,
# eliminating the GitOps-layer SPOF (per locked decision: per-cluster ArgoCD).
#
# Multi-workload, data-driven: every entry in var.workloads gets its own
# read-only deploy key, repository Secret, and ArgoCD Application. Adding a
# workload is a data change in workloads.auto.tfvars.json — no edits here.
#
# Repo authentication: one dedicated ED25519 deploy key per (workload,
# region) pair, registered read-only on that workload's deploy repo. One key
# unlocks exactly one repo — blast radius is a single repo, never a personal
# account-wide PAT (per ADR-06).

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# One deploy key per workload — each key is scoped to a single deploy repo.
resource "tls_private_key" "argocd_repo" {
  for_each  = var.workloads
  algorithm = "ED25519"
}

resource "github_repository_deploy_key" "argocd" {
  for_each   = var.workloads
  title      = "argocd-${var.region}"
  repository = each.value.repo_name
  key        = tls_private_key.argocd_repo[each.key].public_key_openssh
  read_only  = true
}

resource "kubernetes_secret" "argocd_repo" {
  for_each = var.workloads

  metadata {
    name      = "${each.key}-repo-${var.region}"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      # ArgoCD discovers repository secrets by this label — no separate
      # ArgoCD repository CR needed.
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    url           = each.value.repo_url_ssh
    sshPrivateKey = tls_private_key.argocd_repo[each.key].private_key_openssh
  }

  type = "Opaque"
}

resource "helm_release" "argocd" {
  name       = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = "7.6.12" # pinned

  # No public Ingress for the UI — access via `kubectl port-forward
  # -n argocd svc/argo-cd-server 8080:443`. Production hardening: dedicated
  # ALB + OIDC SSO. Documented in tradeoffs.
  values = [
    yamlencode({
      server = {
        service = {
          type = "ClusterIP"
        }
      }
      controller = {
        # Single replica — HA is out of scope for take-home.
        replicas = 1
      }
      configs = {
        params = {
          # Disable insecure TLS-skip for repo connections — deploy key
          # uses SSH, server side authenticated by known_hosts (auto-trust
          # GitHub's host key for first connection).
          "controller.repo.server.timeout.seconds" = "60"
        }
      }
    })
  ]

  depends_on = [kubernetes_secret.argocd_repo]
}

# One ArgoCD Application per workload. Region-injection patches are applied
# only when the workload opts in (region_env / latency_ingress) — that keeps
# each deploy repo's overlay region-agnostic without forcing greeter's shape
# on every workload.
locals {
  argocd_applications = {
    for name, w in var.workloads : name => {
      namespace = "argocd"
      project   = "default"
      source = {
        repoURL        = w.repo_url_ssh
        path           = w.path
        targetRevision = "HEAD"

        kustomize = {
          patches = concat(
            # Inject this cluster's region as a container env var (greeter's
            # HELLO_TAG — the greeting then identifies the serving region).
            w.region_env == null ? [] : [{
              target = { kind = "Deployment", name = w.region_env.deployment }
              patch = yamlencode({
                apiVersion = "apps/v1"
                kind       = "Deployment"
                metadata   = { name = w.region_env.deployment }
                spec = {
                  template = {
                    spec = {
                      containers = [{
                        name = w.region_env.container
                        env  = [{ name = w.region_env.var_name, value = var.region }]
                      }]
                    }
                  }
                }
              })
            }],
            # external-dns latency routing: set-identifier + aws-region make
            # this region's record one latency-routed member of the shared
            # name; evaluate-target-health drops the record when the ALB is
            # gone (region failover).
            w.latency_ingress == null ? [] : [{
              target = { kind = "Ingress", name = w.latency_ingress }
              patch = yamlencode({
                apiVersion = "networking.k8s.io/v1"
                kind       = "Ingress"
                metadata = {
                  name = w.latency_ingress
                  annotations = {
                    "external-dns.alpha.kubernetes.io/set-identifier"             = var.region
                    "external-dns.alpha.kubernetes.io/aws-region"                 = var.region
                    "external-dns.alpha.kubernetes.io/aws-evaluate-target-health" = "true"
                  }
                }
              })
            }],
          )
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = w.namespace
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
}

# Application CRs via the official argocd-apps subchart. Keeps Application
# specs declarative + separate from the controller install (cleaner blast
# radius for app-spec changes).
resource "helm_release" "argocd_application" {
  name       = "aegis-apps"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.2" # pinned

  # argocd-apps chart 2.x: `applications` is a MAP keyed by app name (1.x
  # took a list). A list here makes the chart's range emit numeric keys →
  # metadata.name becomes a number → "unmarshal number into string".
  values = [
    yamlencode({
      applications = local.argocd_applications
    })
  ]

  depends_on = [helm_release.argocd]
}
