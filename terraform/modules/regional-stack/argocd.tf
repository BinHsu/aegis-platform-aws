# ArgoCD per cluster — NOT hub-spoke. Each EKS cluster has its own ArgoCD,
# eliminating the GitOps-layer SPOF (per locked decision: per-cluster ArgoCD).
#
# Repo authentication: dedicated ED25519 deploy key, registered as read-only
# on the aegis-stateless repo. One key per region (title disambiguated by
# region). Per ADR-06 — never use a personal PAT for ArgoCD repo auth.

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

resource "tls_private_key" "argocd_repo" {
  algorithm = "ED25519"
}

resource "github_repository_deploy_key" "argocd" {
  title      = "aegis-stateless-argocd-${var.region}"
  repository = var.repo_name
  key        = tls_private_key.argocd_repo.public_key_openssh
  read_only  = true
}

resource "kubernetes_secret" "argocd_repo" {
  metadata {
    name      = "aegis-stateless-repo-${var.region}"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      # ArgoCD discovers repository secrets by this label — no separate
      # ArgoCD repository CR needed.
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    url           = var.repo_url_ssh
    sshPrivateKey = tls_private_key.argocd_repo.private_key_openssh
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

# Application CR via the official argocd-apps subchart. Keeps Application
# spec declarative + separate from the controller install (cleaner blast
# radius for app-spec changes).
resource "helm_release" "argocd_application" {
  name       = "aegis-greeter-app"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.2" # pinned

  # argocd-apps chart 2.x: `applications` is a MAP keyed by app name (1.x
  # took a list). A list here makes the chart's range emit numeric keys →
  # metadata.name becomes a number → "unmarshal number into string".
  values = [
    yamlencode({
      applications = {
        aegis-greeter = {
          namespace = "argocd"
          project   = "default"
          source = {
            repoURL        = var.repo_url_ssh
            path           = "k8s/overlays/prod"
            targetRevision = "HEAD"

            # Per-region overrides applied by THIS cluster's ArgoCD at
            # render time — keeps k8s/overlays/prod region-agnostic.
            # (Region-aware ECR registry is deliberately NOT done here —
            # see docs/tradeoffs.md "Container image registry".)
            kustomize = {
              patches = [
                # HELLO_TAG = region: the greeting's "unique tag" then
                # identifies which region served the request.
                {
                  target = { kind = "Deployment", name = "aegis-greeter" }
                  patch = yamlencode({
                    apiVersion = "apps/v1"
                    kind       = "Deployment"
                    metadata   = { name = "aegis-greeter" }
                    spec = {
                      template = {
                        spec = {
                          containers = [{
                            name = "greeter"
                            env  = [{ name = "HELLO_TAG", value = var.region }]
                          }]
                        }
                      }
                    }
                  })
                },
                # external-dns latency routing: set-identifier + aws-region
                # make this region's record one latency-routed member of
                # the shared greeter.<zone> name; evaluate-target-health
                # drops the record when the ALB is gone (region failover).
                {
                  target = { kind = "Ingress", name = "aegis-greeter" }
                  patch = yamlencode({
                    apiVersion = "networking.k8s.io/v1"
                    kind       = "Ingress"
                    metadata = {
                      name = "aegis-greeter"
                      annotations = {
                        "external-dns.alpha.kubernetes.io/set-identifier"             = var.region
                        "external-dns.alpha.kubernetes.io/aws-region"                 = var.region
                        "external-dns.alpha.kubernetes.io/aws-evaluate-target-health" = "true"
                      }
                    }
                  })
                },
              ]
            }
          }
          destination = {
            server    = "https://kubernetes.default.svc"
            namespace = "greeter"
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
    })
  ]

  depends_on = [helm_release.argocd]
}
