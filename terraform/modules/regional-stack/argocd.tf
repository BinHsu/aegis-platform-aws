# ArgoCD per cluster — NOT hub-spoke. Each EKS cluster runs its own ArgoCD,
# eliminating the GitOps-layer SPOF (per locked decision: per-cluster ArgoCD).
#
# Self-ownership model (ADR-07): the workload catalog is no longer a JSON map
# iterated by `for_each`. It is a QUERY — an ApplicationSet with a GitHub
# SCM-provider generator discovers every repo tagged with the topic
# `aegis-workload` and reconciles it. Onboarding a workload is: tag the deploy
# repo + add a (gitignored) registry entry. Zero edits here.
#
# Repo authentication (ADR-07 / decision D2): the deploy repos are PUBLIC, so
# ArgoCD clones them anonymously over HTTPS — the per-workload ED25519 deploy
# keys this file used to mint are GONE. The only credential left is one
# org-read token the SCM generator uses to ENUMERATE repos by topic (the GitHub
# API needs auth even for public repos). One token, platform-scoped, not one
# key per workload. If a future deploy repo is private, it needs an
# org-credential here — the public assumption is load-bearing.
#
# ⚠️ implemented, E2E PENDING platform bootstrap — none of the discovery /
# isolation flow has run against a live cluster. Issue #6 gate: ApplicationSet
# discovers BOTH aegis-workload repos + reconciles them; the AppProject blocks
# a deliberately cross-namespace manifest.

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

# The single org-read token the SCM-provider generator uses to list repos by
# topic. Replaces the whole per-workload deploy-key mechanism (D2).
resource "kubernetes_secret" "scm_token" {
  metadata {
    name      = "github-scm-token"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      # ArgoCD picks up SCM credentials from labelled secrets.
      "argocd.argoproj.io/secret-type" = "repo-creds"
    }
  }
  data = {
    token = var.scm_token
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
          "controller.repo.server.timeout.seconds" = "60"
        }
      }
    })
  ]

  depends_on = [kubernetes_secret.scm_token]
}

# Per-workload params the SCM generator cannot know — all ACCOUNT-bound or
# cluster-bound (the values a public deploy repo must not hardcode):
#   - the ECR registry to inject (account-ID hide, D4);
#   - for workloads with IAM, the engine SA + the ARN of the ACK-provisioned
#     role (built from the caller identity = the cluster/platform account, so
#     no account ID lands in any public repo — it lives only in TF state + the
#     in-cluster ApplicationSet);
#   - for workloads with a TLS gateway, the ACM cert ARN to inject onto the
#     Ingress (the cert ARN embeds an account ID — ⑥).
# Region (workload INTENT, not account-bound) is deliberately NOT here — greeter
# owns it via its own kustomize replacements off the injected region annotation.
#
# Every element carries every key (empty string when absent) so the
# ApplicationSet template's `missingkey=error` stays safe while the
# `{{- if ... }}` guards key off empty strings. engine_irsa / ingress_cert are
# opt-in: greeter declares neither.
locals {
  workload_list_elements = [
    for repo, cfg in var.workload_registries : {
      repository = repo
      # url + branch were previously supplied by the SCM-provider generator; the
      # List generator now carries them (see the generators block) so discovery
      # works on a personal GitHub account too (the SCM provider is org-only).
      url                  = "https://github.com/${var.github_owner}/${repo}"
      branch               = "HEAD"
      ecrAccountId         = cfg.ecr_account_id
      ecrRegion            = cfg.ecr_region
      engineServiceAccount = try(cfg.engine_irsa.service_account, "")
      engineRoleArn        = cfg.engine_irsa == null ? "" : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${cfg.engine_irsa.role_name}"
      ingressName          = try(cfg.ingress_cert.ingress_name, "")
      certArn              = try(cfg.ingress_cert.cert_arn, "")
    }
  ]
}

# ApplicationSet + AppProject ship via the argocd-apps subchart (same reason as
# before: declarative app-spec, separate blast radius from the controller; and
# it sidesteps kubernetes_manifest's CRD-at-plan-time problem).
resource "helm_release" "argocd_apps" {
  name       = "aegis-apps"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.2" # pinned

  values = [
    yamlencode({
      # ── ENFORCEMENT FOUR-PACK #1 — namespace-squatting defense ──────────
      # ONE shared AppProject, not one per workload. ArgoCD cannot GENERATE an
      # AppProject from an ApplicationSet, so per-workload projects would
      # re-introduce a platform PR per onboard — defeating self-service. The
      # squatting wall is instead: (a) the ApplicationSet DERIVES each app's
      # destination namespace from the repo name (a deploy repo cannot pick
      # its own namespace — the value comes from the discovered repo, not from
      # anything inside it), backed by (b) this project's destination allowlist
      # (`aegis-*` only) and (c) sourceRepos pinned to the BinHsu org. Decision
      # flagged for review.
      projects = {
        aegis-workloads = {
          namespace   = "argocd"
          description = "All aegis-workload-tagged deploy repos. Destinations locked to aegis-* namespaces; sources locked to the org. ADR-07 enforcement #1. E2E PENDING bootstrap."
          sourceRepos = ["https://github.com/${var.github_owner}/*"]
          destinations = [{
            server    = "https://kubernetes.default.svc"
            namespace = "aegis-*"
          }]
          # CreateNamespace=true makes a (cluster-scoped) Namespace; ACK
          # Role/Policy CRDs are namespaced. Allow both, scoped by the
          # destination allowlist above.
          clusterResourceWhitelist   = [{ group = "", kind = "Namespace" }]
          namespaceResourceWhitelist = [{ group = "*", kind = "*" }]
        }
      }

      applicationsets = {
        aegis-workloads = {
          namespace         = "argocd"
          goTemplate        = true
          goTemplateOptions = ["missingkey=error"]

          # User-account fix: ArgoCD's github SCM-provider generator only lists
          # ORG repos (GET /orgs/<org>/repos) and 404s for a personal account, so
          # topic-discovery never produced an Application on prod (github_owner is a
          # user, not an org). Drive the workload set from the registries-backed
          # List generator instead — each element carries the repo + its registry
          # params + (now) its url + branch. Works for users and orgs alike; the
          # platform's workload set is the registries SoT. Per ADR-07, a deploy
          # repo's argocd/application.yaml marker is still its opt-in intent
          # (enforced out-of-band); the effective Application is RENDERED by the
          # template below, which injects region + registry the repo cannot know.
          # The org-only SCM topic-discovery is dropped (cannot work for a personal
          # account); re-add a merge with scmProvider if you move to a GitHub org.
          generators = [{
            list = {
              elements = local.workload_list_elements
            }
          }]

          template = {
            metadata = {
              name = "{{trimSuffix \"-deploy\" .repository}}"
            }
            spec = {
              project = "aegis-workloads"
              source = {
                repoURL        = "{{.url}}"
                targetRevision = "{{.branch}}"
                path           = "k8s/overlays/prod"
                kustomize = {
                  # D4 account-ID hide — registry injected here, so deploy
                  # repos carry only the bare `name:<tag>` image ref (no
                  # account ID). newName only; the tag stays in the base
                  # manifests where workload CI rewrites it.
                  images = ["{{trimSuffix \"-deploy\" .repository}}={{.ecrAccountId}}.dkr.ecr.{{.ecrRegion}}.amazonaws.com/{{trimSuffix \"-deploy\" .repository}}"]
                  # D3 region injection — a single generic annotation the
                  # cluster knows. A region-aware workload (greeter) reads it
                  # via its own kustomize replacements; the platform does not
                  # know any workload's internal deployment/container names.
                  commonAnnotations = {
                    "aegis.binhsu.org/region" = var.region
                  }
                }
              }
              destination = {
                server    = "https://kubernetes.default.svc"
                namespace = "{{trimSuffix \"-deploy\" .repository}}"
              }
              syncPolicy = {
                automated   = { prune = true, selfHeal = true }
                syncOptions = ["CreateNamespace=true"]
              }
            }
          }

          # Conditional, account-bound injections (each keyed off an empty
          # string so a workload that declares neither — e.g. greeter — renders
          # nothing): the engine SA's role-arn annotation (pointing at the
          # ACK-provisioned role in this account) and the gateway Ingress's ACM
          # cert-arn (⑥ account-ID hide). Region is NOT here — it is
          # workload-owned via the deploy repo's kustomize replacements.
          templatePatch = <<-EOT
            {{- if or .engineRoleArn .certArn }}
            spec:
              source:
                kustomize:
                  patches:
                  {{- if .engineRoleArn }}
                    - target:
                        kind: ServiceAccount
                        name: {{ .engineServiceAccount }}
                      patch: |-
                        - op: add
                          path: /metadata/annotations/eks.amazonaws.com~1role-arn
                          value: {{ .engineRoleArn }}
                  {{- end }}
                  {{- if .certArn }}
                    - target:
                        kind: Ingress
                        name: {{ .ingressName }}
                      patch: |-
                        - op: add
                          path: /metadata/annotations/alb.ingress.kubernetes.io~1certificate-arn
                          value: {{ .certArn }}
                  {{- end }}
            {{- end }}
          EOT
        }
      }
    })
  ]

  depends_on = [helm_release.argocd]
}
