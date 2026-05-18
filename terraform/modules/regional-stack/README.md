# regional-stack module

Self-contained per-region stack: VPC + EKS + IRSA + ALB controller + per-cluster ArgoCD + Grafana Alloy DaemonSet (with node-exporter + kube-state-metrics subcharts).

Invoked from `terraform/envs/regional/main.tf` via `module "stack" { for_each = var.regions ... }`. One module instance per declared region.

## Composition

| File | Purpose |
|---|---|
| `versions.tf` | Pinned providers (aws / kubernetes / helm / tls / github). |
| `variables.tf` | All inputs (region, vpc_cidr, node sizing, ECR/zone refs, GC creds, repo refs, tags). |
| `locals.tf` | Derived names (`aegis-<region>` cluster), subnet CIDR carving via `cidrsubnet`. |
| `vpc.tf` | `terraform-aws-modules/vpc/aws` ~> 5.13. 3 AZs, public + private, single NAT (FinOps tradeoff). EKS/ELB subnet tags applied. |
| `eks.tf` | `terraform-aws-modules/eks/aws` ~> 20.24. K8s 1.30, managed node group on Spot, all 5 control-plane log types → CW (audit side-effect per ADR-04). |
| `irsa-alb.tf` | IRSA role for ALB controller (via the iam-role-for-service-accounts-eks submodule's built-in `attach_load_balancer_controller_policy`). |
| `alb-controller.tf` | `aws-load-balancer-controller` Helm chart 1.8.1, SA annotated with the IRSA role. |
| `argocd.tf` | Per-cluster ArgoCD (chart 7.6.12). ED25519 deploy key registered on the aegis-stateless repo (read-only, per-region title). K8s Secret labeled `argocd.argoproj.io/secret-type=repository` so ArgoCD auto-discovers. Application CR via `argocd-apps` subchart 2.0.2 pointing at `k8s/overlays/prod`. |
| `alloy.tf` + `alloy-config.river.tpl` | Grafana Alloy DaemonSet (chart 0.10.1) — scrapes node-exporter + kube-state-metrics + cAdvisor, OTLP gRPC receiver on :4317, Pyroscope receiver on :4040, Loki source from pod stdout. K8s Secret holds GC creds (sourced via SSM Parameter Store in the regional env layer, passed in as module vars). |
| `outputs.tf` | `cluster_name` / `cluster_endpoint` / `cluster_ca_certificate` / `oidc_provider_arn` / `vpc_id`. **No `alb_dns_name`** — see note below. |

## Why no `alb_dns_name` output

The greeter ALB is provisioned by the ALB controller in response to an `Ingress` synced by ArgoCD from `k8s/overlays/prod/`. That happens **after** this module's TF apply completes — so the ALB's DNS name is not knowable at TF apply time.

Two options for Route 53 records pointing at the ALB:

1. **external-dns** (recommended; not yet implemented) — install the `external-dns` controller, give it IRSA for Route 53 write, annotate the Ingress with `external-dns.alpha.kubernetes.io/hostname` + `aws-routing-policy: latency` + `set-identifier: <region>`. External-dns watches Ingresses and reconciles Route 53 records. Tracked as Step 6 follow-up in `backlog.md`.
2. **Separate post-apply** — a third `dns/` env that runs after `regional/`, reads each ALB via `data.aws_lb` filtered by tag, and creates the records.

For now the Route 53 hosted zone exists (in `platform/`), demonstrating the latency-routing structure; records are not yet populated.

## DR drill blast radius

`make destroy-regional` destroys this module's instances (VPC, EKS, ALB controller, ArgoCD, Alloy) per region. `platform/` survives (Route 53 zone, ECR repo, Grafana dashboards, SSM creds, ALB-logs S3 bucket).

`make regional` rebuilds: EKS cold provisioning ~15 min + node group + addons ~5 min + ALB readiness ~1-3 min + ArgoCD sync ~30 s = 20-30 min real-world cycle (per ADR-05).
