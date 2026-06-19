# ArgoCD per cluster — NOT hub-spoke. Each EKS cluster runs its own ArgoCD,
# eliminating the GitOps-layer SPOF (per locked decision: per-cluster ArgoCD).
#
# Self-ownership model (ADR-07 D-discovery amended; see PR #24's rationale):
# the workload catalog is driven by the REGISTRIES (var.workload_registries),
# not by GitHub SCM topic-discovery. The github SCM-provider generator uses the
# org API (GET /orgs/<owner>/repos) which returns 404 for a personal account —
# confirmed live on the 2026-06-12 prod proof cluster (applicationset-controller
# logs: "GET /orgs/BinHsu/repos → 404; BinHsu is a USER account, not an org").
# Every Application that generator would have produced was therefore absent.
#
# Fix: the ApplicationSet is driven PURELY by the List generator, whose
# elements come from workload_list_elements (var.workload_registries). A
# workload enrols by getting a registries entry; the `aegis-workload` GitHub
# topic + `argocd/application.yaml` marker are OUT-OF-BAND documentation
# conventions — they are NOT enforced by a pathsExist gate (that gate disappears
# with the SCM generator). Works for users and orgs alike; re-add a merge with
# scmProvider if the account moves to a GitHub org.
#
# Repo authentication (ADR-07 / decision D2): the deploy repos are PUBLIC, so
# ArgoCD clones them anonymously over HTTPS — the per-workload ED25519 deploy
# keys this file used to mint are GONE. The org-read token (kubernetes_secret
# .scm_token) is left in place as an ArgoCD repo-credential but is NO LONGER
# CONSUMED by the ApplicationSet generator. It can be removed in a follow-up
# cleanup once the token rotation policy is confirmed.
#
# ⚠️ E2E PENDING platform bootstrap — the registries-driven flow has not yet
# run against a live cluster (the prod proof used kubectl apply as a workaround).

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

# The org-read token originally used by the SCM-provider generator. The SCM
# generator has been REPLACED by the registries-driven List generator (see the
# header comment above) — this secret is no longer consumed by the
# ApplicationSet. It is left in place as an ArgoCD repo-credential; follow-up
# cleanup: confirm token rotation policy, then remove if not needed.
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
  # B1 (2026-06-11): argo-cd is multi-component (server + repo-server +
  # app-controller + redis + dex); the default 300s deadlines its bring-up on
  # a busy cluster. 600s gives it room.
  timeout = 600

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
#   - the ECR repository URL to inject (account-ID hide, D4) — injected as the
#     aegis.binhsu.org/ecr-repository ANNOTATION, never as kustomize.images
#     (field ownership: kustomize.images belongs exclusively to the deploy
#     repo's digest pin — ADR-12);
#   - for workloads with IAM, the engine SA + the ARN of the ACK-provisioned
#     role (built from the caller identity = the cluster/platform account, so
#     no account ID lands in any public repo — it lives only in TF state + the
#     in-cluster ApplicationSet);
#   - for workloads with a TLS gateway, the ACM cert ARN to inject onto the
#     Ingress (the cert ARN embeds an account ID — ⑥).
# Region (workload INTENT, not account-bound) and the registry annotation share
# one consumption pattern: the platform injects an annotation the cluster
# knows; the deploy repo's own kustomize replacements apply it to its
# manifests (greeter owns where it lands).
#
# Every element carries every key (empty string when absent) so the
# ApplicationSet template's `missingkey=error` stays safe while the
# `{{- if ... }}` guards key off empty strings. engine_irsa / ingress_cert are
# opt-in: greeter declares neither.
locals {
  workload_list_elements = [
    for repo, cfg in var.workload_registries : {
      repository = repo
      # url + branch were previously supplied by the SCM-provider generator.
      # The List generator now carries them so the ApplicationSet template can
      # set repoURL / targetRevision without the SCM generator (which 404s on a
      # personal GitHub account — see the file header comment).
      url          = "https://github.com/${var.github_owner}/${repo}"
      branch       = "HEAD"
      ecrAccountId = cfg.ecr_account_id
      ecrRegion    = cfg.ecr_region
      # engineServiceAccount stays as the GATE for the per-engine ConfigMap
      # injections below (model-store, gateway-oidc). The role-arn annotation and
      # the WorkloadIdentity policyArns it used to also drive are GONE (ADR-21 §A):
      # the engine's IAM is now an EKS Pod Identity association in
      # pod-identity-engine.tf (Terraform-owned role, model-read attached there),
      # not a Crossplane-composed IRSA role injected here. The SA is bare on the
      # deploy side (aegis-core-deploy #22), so no role-arn annotation is patched.
      engineServiceAccount = try(cfg.engine_irsa.service_account, "")
      ingressName          = try(cfg.ingress_cert.ingress_name, "")
      # certArn (WS3-R): default to the per-region module cert when a workload
      # opts into ingress_cert but does not pin its own ARN. The module cert is
      # region-correct by construction (acm.tf, region = var.region), replacing
      # the old single-region flat-map cert_arn. An explicit cert_arn still wins.
      certArn = cfg.ingress_cert == null ? "" : coalesce(try(cfg.ingress_cert.cert_arn, null), aws_acm_certificate_validation.gateway.certificate_arn)
      # ConfigMap injection values (WS3-R, zero-touch): the ApplicationSet fills
      # the aws-binding model-store + gateway-oidc ConfigMaps at sync. Cognito is
      # per-account (region-agnostic for JWT validation). The model bucket is now
      # PER-REGION (ADR-05): it comes from this module's own model-store.tf
      # resource, not the single-region platform output, so each region's engine
      # reads its in-region bucket. Injected only for engine workloads (the gate in
      # templatePatch), so greeter is unaffected.
      modelBucket     = aws_s3_bucket.models.bucket
      cognitoIssuer   = var.cognito_issuer
      cognitoAudience = var.cognito_audience
      cognitoJwks     = var.cognito_jwks_url
    }
  ]
}

# ApplicationSet + AppProject ship via the argocd-apps subchart (same reason as
# before: declarative app-spec, separate blast radius from the controller; and
# it sidesteps kubernetes_manifest's CRD-at-plan-time problem).
resource "helm_release" "argocd_apps" {
  # B1 (2026-06-11): the heavy platform controllers install in parallel and
  # deadline on the default 300s helm timeout during a busy cluster bring-up
  # ("context deadline exceeded"). 600s gives them room.
  timeout    = 600
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
          # Namespace is the ONLY cluster-scoped kind a deploy repo may ship:
          # CreateNamespace=true makes the (cluster-scoped) workload namespace.
          # Everything else a workload ships is namespaced — ACK Role/Policy CRDs,
          # and aegis-core's audio-isolation policy, which is a namespaced kyverno
          # `Policy` (in ns aegis-core), NOT a `ClusterPolicy`. A namespaced Policy
          # is the correct least-privilege kind: its rules only ever match Pods in
          # aegis-core, so it never needed cluster scope. Keeping cluster-scoped
          # kinds to {Namespace} closes the hole where any aegis-workloads repo
          # could otherwise ship cluster-wide kyverno ClusterPolicy — the
          # destination allowlist (`aegis-*`) does NOT constrain cluster-scoped
          # resources, so the whitelist is the only wall. namespaceResourceWhitelist
          # (* / *) covers the namespaced Policy.
          clusterResourceWhitelist = [
            { group = "", kind = "Namespace" },
          ]
          namespaceResourceWhitelist = [{ group = "*", kind = "*" }]
        }
      }

      applicationsets = {
        aegis-workloads = {
          namespace         = "argocd"
          goTemplate        = true
          goTemplateOptions = ["missingkey=error"]

          # REGISTRIES-DRIVEN: workloads are enumerated from var.workload_registries
          # via the List generator. A workload enrols by getting a registries entry;
          # the `aegis-workload` GitHub topic + `argocd/application.yaml` marker are
          # out-of-band conventions (no pathsExist gate — that gate lived on the
          # SCM generator which is dropped here). The SCM-provider generator used
          # GET /orgs/<owner>/repos → 404 for a personal account (BinHsu is a user,
          # not an org); caught live on the 2026-06-12 prod proof cluster.
          # To regain GitHub topic auto-discovery, move to a GitHub org and
          # re-add a merge generator with scmProvider here.
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
                path           = "k8s/overlays/${var.environment}"
                kustomize = {
                  # NO kustomize.images here — that field belongs EXCLUSIVELY
                  # to the deploy repo (its overlay pins the image by digest,
                  # ADR-10). Empirically (kustomize v5.8.1): ArgoCD applies an
                  # images override via `kustomize edit set image`, and a
                  # newName-only entry REPLACES the overlay's digest-only
                  # entry — digest deleted, image renders `:latest`,
                  # ImagePullBackOff. See ADR-12.
                  #
                  # Both injections below are annotations — one generic
                  # channel the cluster knows; the deploy repo's own kustomize
                  # replacements consume them. The platform never learns any
                  # workload's internal deployment/container names.
                  commonAnnotations = {
                    # D3 region injection — workload INTENT, region-aware
                    # workloads (greeter) read it via replacements.
                    "aegis.binhsu.org/region" = var.region
                    # Elements come exclusively from var.workload_registries
                    # (the List generator above), so ecrAccountId/ecrRegion are
                    # never absent — a repo with no registry entry is never
                    # enumerated, it cannot reach this template with empties.
                    # D4 account-ID hide — full ECR repository URL, NO
                    # tag/digest. The deploy repo replaces the registry half
                    # of its image ref (replacement delimiter `@`, index 0)
                    # and keeps its own digest. ADR-12.
                    "aegis.binhsu.org/ecr-repository" = "{{.ecrAccountId}}.dkr.ecr.{{.ecrRegion}}.amazonaws.com/{{trimSuffix \"-deploy\" .repository}}"
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
          # nothing): the gateway Ingress's ACM cert-arn (⑥ account-ID hide) and
          # the per-engine ConfigMap values (model bucket, Cognito OIDC). Region
          # and the ECR repository are NOT here — both ride the commonAnnotations
          # channel above and are workload-owned via the deploy repo's kustomize
          # replacements.
          #
          # The engine SA role-arn annotation and the WorkloadIdentity policyArns
          # patch are GONE (ADR-21 §A): the engine's IAM is now an EKS Pod
          # Identity association (pod-identity-engine.tf), not a Crossplane-
          # composed IRSA role injected onto a bare SA here. The gate keys off
          # engineServiceAccount (the ConfigMap injections still need it) and
          # certArn.
          templatePatch = <<-EOT
            {{- if or .engineServiceAccount .certArn }}
            spec:
              source:
                kustomize:
                  patches:
                  {{- if .certArn }}
                    - target:
                        kind: Ingress
                        name: {{ .ingressName }}
                      patch: |-
                        - op: add
                          path: /metadata/annotations/alb.ingress.kubernetes.io~1certificate-arn
                          value: {{ .certArn }}
                  {{- end }}
                  {{- if and .engineServiceAccount .modelBucket }}
                    - target:
                        kind: ConfigMap
                        name: {{ trimSuffix "-deploy" .repository }}-model-store
                      patch: |-
                        - op: replace
                          path: /data/bucket
                          value: {{ .modelBucket }}
                  {{- end }}
                  {{- if and .engineServiceAccount .cognitoIssuer .cognitoAudience .cognitoJwks }}
                    - target:
                        kind: ConfigMap
                        name: {{ trimSuffix "-deploy" .repository }}-gateway-oidc
                      patch: |-
                        - op: replace
                          path: /data/issuer
                          value: {{ .cognitoIssuer }}
                        - op: replace
                          path: /data/audience
                          value: {{ .cognitoAudience }}
                        - op: replace
                          path: /data/jwksUrl
                          value: {{ .cognitoJwks }}
                  {{- end }}
            {{- end }}
          EOT
        }
      }
    })
  ]

  # argo_rollouts must precede the ApplicationSet: aegis-core's gateway/engine
  # are argoproj.io Rollouts, so the controller running first (and its CRD
  # registered) before ArgoCD starts syncing aegis-core avoids a transient
  # `Rollout.argoproj.io "" not found` sync failure on the first bring-up.
  depends_on = [
    helm_release.argocd,
    helm_release.argo_rollouts,
  ]
}
