# Changelog

All notable changes to this project are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project uses [Semantic Versioning](https://semver.org/).

---

## [Unreleased]

### Added
- Community health files: `CONTRIBUTING.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`,
  issue templates, PR template, `CODEOWNERS`.
- `CHANGELOG.md` (this file).
- README: CI badge, license badge, OpenSSF Scorecard badge.
- OpenSSF Scorecard workflow (`.github/workflows/scorecard.yml`).
- RETRO moved to `docs/postmortems/` — maintains permalink.
- C4-L3 component diagram for `terraform/modules/regional-stack` in README Architecture section.

---

## [v0.2.3] — 2026-06-18

### Fixed
- Region-suffix appended to global IAM policy names so dual-region apply does not
  collide on shared IAM namespace (`fix(ws3): region-suffix global IAM policy names`).

---

## [v0.2.2] — 2026-06-18

### Fixed
- Cold-start zone fallbacks must be valid placeholder strings, not empty — empty
  strings fail Route 53 record validation (`fix(ws3): cold-start gate zone placeholders`).
- Cold-start version-gate plan now survives an empty platform state (no prior apply).

---

## [v0.2.1] — 2026-06-18

### Fixed
- Cold-start gate: version-gate plan no longer fails when platform state is empty
  on a net-new regional apply.
- Promoted prod to dual-region (eu-central-1 + eu-west-1) in a separate commit to
  isolate the structural change from the gate fix.

---

## [v0.2.0] — 2026-06-18

WS3 production dual-region release — eu-central-1 (primary) + eu-west-1 (secondary).
Five critical cold-start bugs fixed; E2E staging verification complete.

### Added
- Dual-region prod topology as data (`regions.auto.tfvars.json`).
- Frontend SPA edge: S3 + CloudFront + ACM in the platform tier (`feat(ws3): IaC the
  frontend SPA edge`).
- Per-env DNS subdomain under `aws.binhsu.org` (Cloudflare-delegated, symmetric
  across regions).
- Two-region HTTPS + region/account naming normalization.
- Per-region ACM certificate for the gateway ALB (replaces the single platform-region cert).
- Per-region model S3 bucket (`aegis-core-models-<acct>-<region>`) — no cross-region
  GET on the model hot path.
- Cognito pre-token Lambda: injects `custom:tenant_id` into the ID token (ADR-20).
- Crossplane upjet `provider-aws-iam` replaces ACK for workload IRSA (`fix(ws3): replace
  ACK with Crossplane upjet provider-aws-iam`).
- CI: `infra-staging.yml` + `infra-prod.yml` dispatchers; staging env flag.
- CI: self-healing orphaned Terraform state locks.
- CI: `ALLOW_PARTIAL_APPLY` gate (false = reaper ON — named to reflect intent, not
  negation).
- ADR-19 (public edge: Route 53 + ACM + Cognito OIDC).

### Fixed
- VPC teardown wedge on orphaned ALB-controller SG: two-phase SG sweep with retry.
- ACM DNS-01 validation records keyed on `domain_name` (not `resource_record_name`)
  to avoid "Invalid for_each" on first creation.
- Adopted pre-existing shared-greeter ECR registry into platform state (no drift).
- `TF_VAR_environment` now passed to `apply-platform`; staging dispatch added.
- ECR `DescribeImages` permission; Kyverno UID 65534.
- `BOOTSTRAP_COMPLETE` reset logic.
- VPC SG dependency violation on destroy.

### Changed
- ArgoCD ApplicationSet migrated from SCM-provider generator (404s on personal GitHub
  accounts) to registries-driven List generator (ADR-07 amendment).
- Per-account ECR dropped — consolidated to deployment-account registry (ADR-10 ph2).
- IRSA role name uniqueness: region-suffix appended to prevent dual-region name
  collision.

---

## [v0.1.0] — 2026-06-12

First WS3 release. Phase A platform stack verified against a live prod proof cluster.

### Added
- Crossplane core + `WorkloadIdentity` XRD/Composition (ADR-09): deploy repos declare
  IAM intent as a `WorkloadIdentity` claim; the platform Composition renders the IAM
  role. Trust subject derived from the claim's own namespace — a claim cannot forge a
  foreign-namespace trust.
- Kyverno 5th-layer guardrails: trust-subject↔namespace enforcement, default-deny
  NetworkPolicy baseline.
- EKS managed node groups with Spot capacity; core addons (vpc-cni/kube-proxy/coredns)
  installed before node group join to avoid `cni plugin not initialized` on first apply.
- Grafana Alloy DaemonSet: OTLP + Pyroscope → Grafana Cloud (Mimir / Loki / Tempo).
- Enable/disable observability toggle (`enable_observability`) — forks without a
  Grafana Cloud stack skip the provider entirely.
- Budget circuit-breaker: manual budget action (A9).
- TTL reaper: generalized beyond EKS to NAT/RDS/ELB (A11).
- ADR-07 (workload self-ownership), ADR-08 (cluster multi-tenancy), ADR-09
  (platform-as-product XRD), ADR-10 (release model: build once, promote by digest).

### Fixed
- Teardown: derive cluster name from state; ALB cleanup scoped by VPC (both layers
  were no-op on a wrong name guess).
- EKS extended-support cost guard: three-layer guard + incident postmortem.
- CI security scanner migrated from `tfsec` to `trivy`.
- `tflint`: declare null provider in `regional-stack required_providers`.
- ArgoCD bring-up timeout extended to 600 s (multi-component; 300 s deadline on busy cluster).

### Changed
- AWS provider bumped to v6; VPC/EKS/IAM modules bumped to major versions aligned
  with provider v6 (ADR-08).
- OIDC trust provider referenced via data source (LZ-owned — not re-created by
  platform).
- GitHub Actions apply role renamed `aegis-platform-aws-apply` →
  `gh-tf-apply-platform`.
- ArgoCD wiring refactored from scalar to data-driven `workloads` map
  (`workloads.auto.tfvars.json` → `for_each`): adding a workload is a data change,
  not a `.tf` change.

[Unreleased]: https://github.com/BinHsu/aegis-platform-aws/compare/v0.2.3...HEAD
[v0.2.3]: https://github.com/BinHsu/aegis-platform-aws/compare/v0.2.2...v0.2.3
[v0.2.2]: https://github.com/BinHsu/aegis-platform-aws/compare/v0.2.1...v0.2.2
[v0.2.1]: https://github.com/BinHsu/aegis-platform-aws/compare/v0.2.0...v0.2.1
[v0.2.0]: https://github.com/BinHsu/aegis-platform-aws/compare/v0.1.0...v0.2.0
[v0.1.0]: https://github.com/BinHsu/aegis-platform-aws/releases/tag/v0.1.0
