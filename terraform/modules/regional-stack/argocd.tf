# ArgoCD per cluster — NOT hub-spoke. Each EKS cluster runs its own ArgoCD,
# eliminating the GitOps-layer SPOF (per locked decision: per-cluster ArgoCD).
#
# A5 (epic #167 / issue #177, ADR-25): the workload ApplicationSet + AppProject
# that USED to live here (helm_release.argocd_apps) MOVED TO GITOPS —
# gitops/platform-addons/addons/workloads/{appproject,applicationset}.yaml, applied
# by the app-of-apps root (directory.recurse) like every other add-on. What stays
# in Terraform: (1) the bootstrap ArgoCD install (helm_release.argocd, below —
# per the epic target end-state, Terraform owns the cluster + a bootstrap ArgoCD),
# and (2) local.workload_list_elements — Terraform still builds the per-workload
# catalog from registries.auto.tfvars.json + AWS resources (the registry facts stay
# TF-owned, epic decision #4), but now WRITES it as the aegis.binhsu.org/workloads
# facts-bridge annotation (gitops-bootstrap.tf) for the git ApplicationSet to read,
# instead of interpolating it into an inline Helm List generator. See the MIGRATION
# tombstone at the bottom of this file for WHAT MOVED WHERE / REVERT.
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
# keys this file used to mint are GONE. The org-read token this module used to
# thread into an ArgoCD repo-credential Secret (kubernetes_secret.scm_token,
# backing the now-removed SCM-provider generator) has itself been REMOVED
# (2026-07-06 cleanup) — nothing consumed it. var.scm_token / var.github_token
# are no longer wired through this env.
#
# ⚠️ E2E PENDING platform bootstrap — the registries-driven flow has not yet
# run against a live cluster (the prod proof used kubectl apply as a workaround).

resource "kubernetes_namespace" "argocd" {
  # Wait for the EKS access-entry -> authorizer propagation (eks.tf): this is the
  # first cluster-scoped create and it hit "namespaces is forbidden" on the WS4
  # dual-region burn (run 27843245290) when the apply role's ClusterAdmin grant
  # had not yet propagated. Gating the namespace on the sleep gates the whole
  # argocd subtree (secret + helm releases chain off it).
  depends_on = [terraform_data.eks_access_propagation]

  metadata {
    name = "argocd"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
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
#
# A5 (issue #177): these elements are NO LONGER interpolated into an inline Helm
# List generator here. Terraform now writes jsonencode(local.workload_list_elements)
# as the aegis.binhsu.org/workloads annotation on the facts-bridge cluster Secret
# (gitops-bootstrap.tf), and the git ApplicationSet
# (gitops/platform-addons/addons/workloads/applicationset.yaml) reads it back via a
# Matrix(clusters × list.elementsYaml) generator. The element SHAPE is unchanged
# except two keys that used to be template-level TF interpolations and now ride the
# element so the git template stays cluster-agnostic AND identical to the harness
# copy: `path` (was the fixed k8s/overlays/${var.environment}) and `region` (was
# var.region inlined into commonAnnotations).
locals {
  workload_list_elements = [
    for repo, cfg in var.workload_registries : {
      repository = repo
      # url + branch were previously supplied by the SCM-provider generator.
      # The List generator now carries them so the ApplicationSet template can
      # set repoURL / targetRevision without the SCM generator (which 404s on a
      # personal GitHub account — see the file header comment).
      url    = "https://github.com/${var.github_owner}/${repo}"
      branch = "HEAD"
      # Deploy-repo overlay path. Was a fixed k8s/overlays/${var.environment} in the
      # ApplicationSet template; element-carried now (A5) so the git template is a
      # single {{.path}} shared by the platform and the kind harness.
      path         = "k8s/overlays/${var.environment}"
      ecrAccountId = cfg.ecr_account_id
      ecrRegion    = cfg.ecr_region
      # D3 region injection value. Was var.region inlined into the template's
      # commonAnnotations; element-carried now (A5) for the same single-template
      # reason as `path`.
      region = var.region
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

# ── MIGRATION TOMBSTONE — workload ApplicationSet + AppProject → GITOPS (A5) ──
# (epic #167 A5 / issue #177, ADR-25 ownership inversion)
#
# This file previously held helm_release.argocd_apps: the aegis-workloads
# AppProject + the workload ApplicationSet (the List generator, template, and the
# per-workload/per-account templatePatch — the values-passing CRUX of the epic),
# shipped via the argocd-apps subchart. A5 moved ALL of that out of Terraform into
# ArgoCD, as two app-of-apps children under gitops/platform-addons/addons/workloads/:
#   - appproject.yaml       (AppProject aegis-workloads; sync-wave 2)
#   - applicationset.yaml   (ApplicationSet aegis-workloads; object sync-wave 2,
#                            generated Applications sync-wave 3)
# The app-of-apps root that delivers them: gitops/platform-addons/root-app.yaml,
# seeded from Terraform in gitops-bootstrap.tf.
#
# WHY: Terraform owning these in-cluster objects is the ownership mismatch epic
# #167 dissolves — `terraform destroy` no longer helm-uninstalls the argocd-apps
# release (the cluster delete reaps it), removing the last add-on off Terraform
# state. This is the epic's final A-stage: the workload ApplicationSet is the ONE
# place per-workload, per-account config is injected, so it was the deliberate last
# move (a valid A4 stopping point existed — Bin chose MIGRATE, 2026-07-06, #177).
#
# WHAT MOVED WHERE:
#   - AppProject aegis-workloads (squatting wall)  → addons/workloads/appproject.yaml
#     sourceRepos = github.com/${github_owner}/*     (git-static; owner is a PUBLIC
#                                                      handle, hardcoded like root-app
#                                                      .yaml — a fork edits one line)
#   - ApplicationSet template + templatePatch      → addons/workloads/applicationset.yaml
#     (per-workload/per-account injections)          (VERBATIM — no rendered-Application
#                                                      regression, #177's must-pass gate)
#   - List generator elements                      → the FACTS BRIDGE: Terraform writes
#     (local.workload_list_elements, still built     jsonencode(local.workload_list_elements)
#      from registries.auto.tfvars.json + AWS         as the aegis.binhsu.org/workloads
#      resources, above)                              annotation on the cluster Secret
#                                                      (gitops-bootstrap.tf); the git
#                                                      ApplicationSet reads it back with a
#                                                      Matrix(clusters × list.elementsYaml).
#                                                      registries.auto.tfvars.json stays the
#                                                      source of truth (epic decision #4).
#   - depends_on = [helm_release.argocd]           → ArgoCD is a Terraform-owned bootstrap
#     (ApplicationSet after ArgoCD)                  install (helm_release.argocd, above); the
#                                                      root app seeds only after ArgoCD exists
#                                                      (gitops-bootstrap.tf depends_on).
#   - A4 residual (no hard Rollout-CRD gate)        → sync-wave ordering (workloads wave 3,
#                                                      after argo-rollouts wave 0) + a retry
#                                                      block on the generated Application.
#                                                      Closes the transient
#                                                      `Rollout.argoproj.io "" not found`
#                                                      window. See applicationset.yaml ORDERING.
#
# WHAT STAYED IN TERRAFORM (this file, above): the bootstrap ArgoCD install
# (helm_release.argocd + its namespace) and local.workload_list_elements (the
# workload catalog Terraform feeds to the facts-bridge annotation). No workload
# ApplicationSet, no AppProject.
#
# REVERT: `git revert` restores helm_release.argocd_apps here (the AppProject +
# ApplicationSet + its depends_on), removes the two GitOps files under
# addons/workloads/, and removes the aegis.binhsu.org/workloads annotation in
# gitops-bootstrap.tf. Single logical boundary.
