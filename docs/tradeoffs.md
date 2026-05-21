# Trade-offs and deferred work

What this project deliberately did *not* build, why, and what production-grade
would look like. Each item names the **trigger** that would justify doing it and
a rough **effort** estimate — the point is to show the work was planned, not
overlooked.

This is the honest counterpart to the README: the system is right-sized for a
cost-bounded take-home, not pretended to be production-complete.

---

## Resilience

### Single NAT gateway

`modules/regional-stack` provisions one NAT gateway per VPC, shared across AZs.
A NAT-AZ failure takes out egress for private subnets in the other AZs.

- **Production**: one NAT gateway per AZ (`single_nat_gateway = false`).
- **Trigger**: an availability SLA that counts AZ-level egress failures.
- **Effort**: one variable flip; ~3× NAT cost.

### ArgoCD single replica

ArgoCD runs one replica per cluster. A controller restart pauses reconciliation
(it does not affect running workloads).

- **Production**: ArgoCD HA mode (Redis HA + multiple controller/repo-server
  replicas).
- **Trigger**: reconciliation latency becomes operationally visible.
- **Effort**: ~0.5 day (chart values).

---

## Security

### EKS public API endpoint

The EKS API server is reachable from the internet (`0.0.0.0/0`) so the operator
and CI can run `terraform`/`kubectl` without a bastion. tfsec flags this; it is a
deliberate, documented choice for the take-home.

- **Production**: private endpoint + a bastion / VPN / AWS SSM Session Manager,
  or `cluster_endpoint_public_access_cidrs` restricted to known office/CI ranges.
- **Trigger**: any production posture.
- **Effort**: ~0.5 day (plus the bastion/VPN it implies).

### IAM apply role is `AdministratorAccess`

`aegis-platform-apply` (the CI apply role) carries `AdministratorAccess`. Its
*trust* is tight — only `repo:BinHsu/aegis-platform:ref:refs/heads/main` — but
its *permissions* are broad.

- **Production**: a bespoke least-privilege policy enumerating exactly the
  create/update/delete actions the Terraform plan needs.
- **Trigger**: production, or a shared AWS account.
- **Effort**: ~1 day (derive the action set from a plan, iterate).

### EKS cluster access lists a single operator

The cluster's EKS access entries are explicit and deterministic — the two CI
roles plus one human operator (`var.operator_principal_arn`). One operator is
fine for a take-home; a team is not a list of individuals.

- **Production**: map an IAM Identity Center (SSO) permission set or an IAM
  group to the access entry, so operator access is granted by group
  membership, not by editing Terraform for every joiner/leaver. Each EKS
  access entry still targets one principal ARN, so the group/SSO role ARN
  becomes the single entry and membership is managed in the identity provider.
- **Trigger**: more than one human needs cluster access.
- **Effort**: ~0.5 day (once an IdP group / SSO permission set exists).
- **Note**: `enable_cluster_creator_admin_permissions` is deliberately off —
  it injects the *running caller's* ARN, which is non-deterministic between a
  local apply and a CI apply. All access is the explicit `access_entries`.

### AWS-managed KMS keys

S3 state, the ALB-logs bucket, ECR, and the SNS topic use AWS-managed keys
(`aws/s3`, `AES256`, `aws/sns`), not customer-managed CMKs.

- **Production**: customer-managed KMS keys with explicit key policies — granular
  access control, cross-account grants, independent rotation.
- **Trigger**: compliance requirements, or cross-account access.
- **Effort**: ~0.5 day.
- **Note**: ALB access-log delivery only supports SSE-S3 — that bucket cannot use
  a CMK regardless. Not a choice, an AWS constraint.

### Branch protection off by default

`github_branch_protection` is gated on `var.enable_branch_protection`, default
`false`. GitHub requires a Pro plan for branch protection on a *private* repo;
a free private repo cannot apply the resource. The CI workflows still run
(`infra-plan` on PR, `infra-apply` on merge) — without the resource, the
"required status checks + linear history" merge gate is convention, not
enforcement.

- **Production**: move to GitHub Pro (keeps the repo private), then set
  `enable_branch_protection = true`. Going *public* would also make branch
  protection free, but a public repo accepts fork PRs and issues from anyone —
  noise to triage, and fork-PR workflow runs to gate (`Settings → Actions →
  Require approval for all outside collaborators`). For review, granting the
  reviewer individual read access is cleaner than going public: no fork
  surface, no public CI logs (which would otherwise expose the AWS account ID
  + ARNs). Public is a deliberate later step for portfolio circulation, not a
  submission requirement.
- **Trigger**: a team setting where merges to `main` must be machine-enforced.
- **Effort**: one variable flip (plus the Pro/public decision).

### Signed commits not enforced

When branch protection *is* enabled, it requires status checks + linear history
but not signed commits.

- **Production**: `require_signed_commits = true`, once every contributor has
  GPG/SSH signing configured.
- **Trigger**: a team with commit-signing set up.
- **Effort**: minutes (one flag) — gated only on contributor onboarding.

### VPC Flow Logs

Not enabled. tfsec flags it.

- **Production**: flow logs → S3 → Athena for network forensics.
- **Trigger**: a network-forensics or compliance requirement.
- **Effort**: ~0.5 day; cost keeps it off-by-default.

### Account-level defenses

GuardDuty, Security Hub, AWS Config are not enabled.

- **Production**: typically enabled org-wide in the management account, not
  per-workload.
- **Trigger**: a compliance audit.
- **Effort**: ~1 day to enable + tune.

### AWS account ID in the committed image manifest

`k8s/overlays/prod/kustomization.yaml` pins the greeter image by its full ECR
URL — `<account-id>.dkr.ecr.<region>.amazonaws.com/aegis-greeter`. An ECR
reference structurally embeds the account ID, and the GitOps flow requires it:
the sibling repo's CI commits the image-tag bump into this manifest, and ArgoCD
renders the manifest as-is. So the committed file carries the account ID. An
account ID is identity surface, not a credential, and the sandbox account is
destroyed after the demo — accepted for the take-home, recorded here, not hidden.

- **Production / clean**: the registry is a deploy-environment concern, not a
  build artifact — so stop CI writing it into git. The CI commit-back then
  writes only `newTag` (a commit SHA, not sensitive); the registry is supplied
  at deploy time. This is the same fix as region-aware ECR — see
  [Container image registry](#container-image-registry): package the greeter as
  a Helm chart with `image.registry` as a per-region value, or mutate the
  registry in at admission with Kyverno. Injecting `newName` via the ArgoCD
  `Application`'s `kustomize.images` does *not* work — that override runs
  `kustomize edit set image`, which replaces the whole image entry and drops
  the CI-bumped `newTag`. The account ID then lives only in Terraform state /
  the cluster, never in git.
- **Trigger**: making the repo public for portfolio circulation.
- **Effort**: folded into the "Container image registry" fix — ~1 day (Helm
  migration). Cleans HEAD onward; the account ID remains in prior commits
  unless history is also rewritten.

---

## ALB access logs

The S3 bucket for ALB access logs is provisioned in `platform/` (Block Public
Access, 7-day lifecycle), but the greeter Ingress does not enable access logs.
The ALB controller requires `access_logs.s3.bucket=<name>` alongside
`access_logs.s3.enabled=true`, and that bucket name embeds the AWS account ID —
which the anonymization policy forbids in a committed manifest.

- **Production**: inject the bucket name at deploy time — an operator-local
  kustomize overlay patch, or a controller that templates the annotation. Then
  ALB access logs land in the (already-provisioned) S3 bucket.
- **Trigger**: a need for per-request ALB access logs (forensics, the request
  URL / client IP / latency that app-level OTel does not capture).
- **Effort**: ~0.5 day (the bucket already exists; only the annotation wiring
  is missing).

## DNS

The Route 53 hosted zone (`aegis-platform.test`) is a placeholder — no real
domain is registered. `.test` is an RFC 6761 special-use TLD: reserved for
testing and guaranteed never to be delegated on the public internet, so the
zone cannot collide with a real domain. (`example.com` would seem the obvious
placeholder but AWS Route 53 explicitly rejects it as reserved.)

external-dns *is* deployed (ADR-05) — it watches the greeter Ingress and
reconciles the per-region Route 53 latency records; the records resolve and
fail over by the latency policy's health-check evaluation.
What is deferred is only the **real domain**: against a `.test` zone,
resolution works only by querying the zone's nameservers directly
(`dig @<assigned-nameserver>`), because `.test` has no public delegation.

- **Production**: register a domain (or delegate a subdomain) and point its NS
  records at the zone's AWS-assigned nameservers. `dig greeter.<domain>` then
  resolves from any resolver — no `@<nameserver>` needed.
- **Trigger**: a publicly reachable service.
- **Effort**: ~0.5 day (domain registration + NS delegation; the hosted zone
  and the latency records already exist).

## Container image registry

The greeter image lives in one ECR repository in the platform region. With
more than one region active, ECR replication mirrors it to each region's
registry — but the workload still pulls from the platform region:
`k8s/overlays/prod/kustomization.yaml` pins one registry, so a second
region's pods pull the image cross-region.

- **Cost**: cross-region image transfer (~$0.02/GB) on each pull not served
  from a node's cache. Sub-cent for a small distroless image at this scale;
  a recurring line item at fleet scale.
- **Why not fixed here**: a per-region registry with an *automated* CI tag
  bump needs the registry and the tag to be independent parameters.
  Kustomize couples them in one `images:` entry, and ArgoCD's
  `kustomize.images` override replaces the whole entry — pinning the tag
  there would freeze out the CI bump and break GitOps auto-sync.
- **Production**: package the greeter as a Helm chart — `image.registry` and
  `image.tag` are then independent values that compose: a per-region
  Application sets the registry, CI bumps the tag. Staying on Kustomize, the
  same registry/tag split is reachable through an ArgoCD Config Management
  Plugin (`kustomize build | envsubst`) with a per-region `${ECR_REGISTRY}`
  placeholder filled from the Application's `plugin.env`. A node-level containerd
  registry mirror looks tempting (redirect a region-agnostic ref at the node,
  manifest untouched) but does **not** cleanly cover cross-region *private*
  ECR: the EKS credential provider issues an ECR auth token for the image
  ref's region, not the mirror's, so the mirrored pull fails auth and falls
  back to the cross-region source. Making it work needs a credential-provider
  helper — a known EKS limitation, not a quick win. A globally distributed
  registry (ghcr.io, a CDN-fronted Harbor) sidesteps the problem entirely.
- **Trigger**: multi-region traffic where cross-region pull cost or latency
  is material.
- **Effort**: ~1 day (Helm migration).

---

## Observability upgrade aspirations

v1 ships the open-observability stack: OpenTelemetry + Grafana Alloy → Grafana
Cloud (Mimir / Loki / Tempo / Pyroscope). Metrics, traces, logs, and continuous
profiling are all live. What remains:

| # | Add | Trigger | Effort |
|---|---|---|---|
| 1 | **SLO + error budget** (Pyrra / Sloth / OpenSLO) — burn-rate alerts replace static thresholds | Real user traffic + an SLA commitment | ~1 day |
| 2 | **AWS WAF** on the ALB + managed rule groups | Public exposure that attracts attack volume | ~0.5 day |
| 3 | **k6 synthetic blackbox** probing of the ALB endpoint | SLO-driven external detection | ~0.5 day |
| 4 | **Out-of-band infra health** — EC2 instance status checks, ALB `HealthyHostCount` / 5xx, the `AWS/EKS` namespace. Shipped as a *gated* Grafana CloudWatch datasource (`enable_cloudwatch_datasource`, default off): query-time **pull**, so on the free tier these metrics never consume the Mimir active-series budget. The **production end-state is the inverse** — a curated `cloudwatch_exporter` / YACE Deployment that `remote_write`s the *operational subset* into Mimir: one PromQL store, retention you control, cross-metric joins, and alerts evaluated against local data instead of a live CloudWatch `GetMetricData` call per eval (which also bills per request and breaks alerting if the API throttles). The datasource then keeps a niche for ad-hoc exploration of metrics not worth ingesting. The pull-vs-push choice is budget-driven, not absolute: free tier → pull; paid → curated push for what you dashboard/alert on. | Infra-layer signals the in-cluster exporters cannot see — and an out-of-band vantage point for when the cluster itself is down | ~0.5 day |
| 5 | **AMP + AMG** (managed Prometheus + Grafana on AWS) | Grafana Cloud free-tier limits breached, or org policy forbids external SaaS for telemetry — migration keeps Alloy + the OTel SDK unchanged, only `remote_write` URLs flip | ~0.5 day |
| 6 | **Cross-region metric/log aggregation** | ≥ 2 regions deployed | ~0.5 day per pair |

The choice not to add distributed tracing depth beyond what `otelhttp` emits is
deliberate: a single-service greeter produces degenerate single-span traces.
Tracing earns its keep once the app gains downstream dependencies.

---

## Delivery pipeline

CI-driven apply is already in place (ADR-03): `infra-apply` runs
`terraform apply` on push to `main`, gated by PR + branch protection. What a
larger setup would add:

- **Plan/apply approval environments** — a GitHub Environment with required
  reviewers in front of `infra-apply`, so apply needs an explicit human gate
  beyond PR review. Deliberately omitted: PR review of the plan diff *is* the
  gate, and a second button is Atlantis-era ceremony.
- **Drift detection** — a scheduled `terraform plan` that alerts on out-of-band
  changes. Effort: ~0.5 day.
- **Policy-as-code** — OPA / Conftest gating the plan output against
  organisational policy. Effort: ~1 day.
