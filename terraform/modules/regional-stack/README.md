# regional-stack module

Self-contained per-region stack: VPC + EKS + IRSA + ALB controller + per-cluster ArgoCD + Grafana Alloy DaemonSet (with node-exporter + kube-state-metrics subcharts).

Invoked from `terraform/envs/regional/main.tf` via `module "stack" { for_each = var.regions ... }`. One module instance per declared region.

## Composition

| File | Purpose |
|---|---|
| `versions.tf` | Pinned providers (aws / kubernetes / helm). |
| `variables.tf` | All inputs (region, vpc_cidr, node sizing, zone refs, GC creds, `scm_token`, `workload_registries`, tags). |
| `locals.tf` | Derived names (`aegis-<region>` cluster), subnet CIDR carving via `cidrsubnet`. |
| `vpc.tf` | `terraform-aws-modules/vpc/aws` ~> 5.13. 3 AZs, public + private, single NAT (FinOps tradeoff). EKS/ELB subnet tags applied. |
| `eks.tf` | `terraform-aws-modules/eks/aws` ~> 20.24. K8s 1.30, managed node group on Spot, all 5 control-plane log types → CW (audit side-effect per ADR-04). |
| `irsa-alb.tf` | IRSA role for ALB controller (via the iam-role-for-service-accounts-eks submodule's built-in `attach_load_balancer_controller_policy`). |
| `alb-controller.tf` | `aws-load-balancer-controller` Helm chart 1.8.1, SA annotated with the IRSA role. |
| `argocd.tf` | Per-cluster ArgoCD (chart 7.6.12) + the workload-discovery `ApplicationSet` and shared `AppProject` via `argocd-apps` subchart 2.0.2. SCM-provider generator finds repos by the `aegis-workload` topic (Merge generator joins per-workload registry/IRSA params from `workload_registries`); namespace derived from repo name; ECR registry + region injected. One org-read token in a K8s Secret — no per-workload deploy keys (deploy repos are public). ADR-07. **E2E PENDING bootstrap.** |
| `crossplane.tf` + `irsa-ack-iam.tf` | Crossplane core + the upjet `provider-aws-iam` (shipped by the `aegis-xrds` chart) + its IRSA role `aegis-platform-aws-ack-iam-${region}` (mutations scoped to the `/aegis-workload/` IAM path). A deploy repo declares a `WorkloadIdentity` XR; the Composition renders a cluster-scoped `iam.aws.upbound.io/Role` the provider reconciles into AWS. The role name's `aegis-platform-aws-ack-iam-` prefix is the seam to the fabric SCP carve-out — kept exact so fix B reuses the role with no landing-zone change. fix B (2026-06-18) replaced ACK; `ack-iam.tf` is gone. ADR-07 + ADR-09. |
| `kyverno.tf` + `charts/aegis-policies/` | Kyverno (chart 3.2.6) + ClusterPolicies: ACK Role trust-subject↔namespace match (enforcement #2) and a generated default-deny NetworkPolicy baseline in every `aegis-*` namespace (enforcement #4, ADR-07); a WorkloadIdentity-claim namespace restriction (ADR-09); and a require-image-digest policy (ADR-10, default Audit — flip to Enforce via `require_digest_action` after deploy repos pin `@sha256`). **E2E PENDING bootstrap.** |
| `model-store.tf` | **Per-region** engine model S3 bucket `aegis-core-models-<acct>-<region>` + its read-only managed policy `aegis-core-model-read-<region>` (ADR-05). The ApplicationSet injects the bucket name into the engine's model-store ConfigMap and appends the read policy to the engine's WorkloadIdentity `policyArns`, so each region's engine reads its in-region bucket. Operator/CI must populate **each** region's bucket. |
| `external-dns.tf` + `irsa-external-dns.tf` | `external-dns` (chart 1.21.1) + its IRSA role scoped to the one hosted zone. Reconciles the gateway Ingress into a latency-routed Route 53 record (see "Route 53 records" below). |
| `acm.tf` | Per-region ACM certificate for the gateway ALB (region-bound; one per region). DNS-01 validated in the platform-owned zone. |
| `alloy.tf` + `alloy-config.river.tpl` | Grafana Alloy DaemonSet (chart 0.10.1) — scrapes node-exporter + kube-state-metrics + cAdvisor, OTLP gRPC receiver on :4317, Pyroscope receiver on :4040, Loki source from pod stdout. K8s Secret holds GC creds (sourced via SSM Parameter Store in the regional env layer, passed in as module vars). |
| `outputs.tf` | `cluster_name` / `cluster_endpoint` / `cluster_ca_certificate` / `oidc_provider_arn` / `vpc_id`. **No `alb_dns_name`** — see note below. |

## Route 53 records — external-dns, latency routing (ADR-05)

The ALB is provisioned by the ALB controller in response to an `Ingress` synced by ArgoCD from `k8s/overlays/<env>/`, **after** this module's TF apply completes — so the ALB's DNS name is not knowable at TF apply time. `external-dns` (`external-dns.tf`) closes that gap: it watches the Ingress and reconciles the Route 53 record under the platform-owned zone, after the ALB exists. That is why there is no `alb_dns_name` output — the record is created in-cluster, not in Terraform.

**Latency routing is implemented (ADR-05 dual-region).** Each region's gateway Ingress (in the `aegis-core-deploy` repo, `components/aws-binding/gateway-ingress.yaml`) carries:

| Annotation | Value | Effect |
|---|---|---|
| `external-dns.alpha.kubernetes.io/set-identifier` | `<region>` | Distinguishes the two records that share the host. **Required** for any Route 53 routing policy. |
| `external-dns.alpha.kubernetes.io/aws-region` | `<region>` | Selects **latency** routing. On AWS, external-dns infers the policy from this annotation's presence — there is **no** `aws-routing-policy` annotation for the AWS provider (that spelling is for other providers). Verified against external-dns chart `1.21.1`. |
| `external-dns.alpha.kubernetes.io/aws-evaluate-target-health` | `"true"` | Route 53 reads the ALB **alias** target's health directly and drops the record when the region's ALB is unhealthy → automatic failover. |

The `<region>` placeholders ship as the literal `local` and are rewritten per-region by the deploy overlay's `replacements`, sourcing `aegis.binhsu.org/region` — the annotation `argocd.tf` injects with `var.region`. Each region's external-dns owns only its own record (`txtOwnerId = cluster_name`, `external-dns.tf`), so the two coexist in the shared zone.

**No separate Route 53 health-check resource is needed.** Because the record is an ALB **alias** with `evaluate-target-health=true`, Route 53 evaluates the ALB's own target-group health — there is no standalone `aws_route53_health_check` to declare in Terraform. The external-dns IRSA built-in policy (`irsa-external-dns.tf`, `attach_external_dns_policy = true`) covers the `route53:ChangeResourceRecordSets` writes this needs; health evaluation is a Route 53 server-side behavior of the alias record, not an API call external-dns makes. A non-alias / endpoint health check (the `aws-health-check-id` annotation path) would need an explicit `aws_route53_health_check` — out of scope for the ALB-alias model used here.

## DR drill blast radius

`make destroy-regional` destroys this module's instances (VPC, EKS, ALB controller, ArgoCD, Alloy) per region. `platform/` survives (Route 53 zone, ECR repo, Grafana dashboards, SSM creds, ALB-logs S3 bucket).

`make regional` rebuilds: EKS cold provisioning ~15 min + node group + addons ~5 min + ALB readiness ~1-3 min + ArgoCD sync ~30 s = 20-30 min real-world cycle (per ADR-05).
