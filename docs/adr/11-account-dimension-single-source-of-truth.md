# ADR-11: Account dimension — single source of truth is `accounts.json`

## Status

Accepted (2026-06-10). Extends [ADR-01](01-architecture-and-topology.md)
(topology as data) and [ADR-03](03-delivery-cicd-gitops.md) (CI-driven apply)
to the account dimension. Implemented by the W3 multi-account promotion work
(PR #31, held until the 2026-06-12 window).

## Context

ADR-01 made the **region** dimension data: `regions.auto.tfvars.json` declares
which regions exist, and CI iterates it. The **account** dimension never got the
same treatment. Which AWS account a workflow targets is implicit in a single
set of repo secrets (`AWS_INFRA_APPLY_ROLE_ARN`, `TFSTATE_BUCKET`, …), and the
`BOOTSTRAP_COMPLETE` flag is one repo variable — meaningful only while exactly
one account exists.

Multi-account (staging account `2517…`, prod account `5062…`) breaks that
shape three ways:

1. **Topology hidden in secrets.** A reviewer cannot see from git which
   accounts exist, which regions each enables, or whether an account is
   bootstrapped. Secrets are write-only configuration — the opposite of the
   topology-as-data discipline ADR-01 established for regions.
2. **Per-account secret sprawl.** Every account would need its own
   role-ARN + bucket secret pair, named by convention, rotated by hand —
   N accounts × M values, none of it reviewable.
3. **The reaper and ops workflows are single-account.** They read the one
   secret set, so they can scan and destroy in exactly one account.

The landing-zone already standardised the role name (`gh-tf-apply-platform`,
in the org SCP's `gh-tf-*` glob) and the state-bucket naming
(`aegis-platform-aws-tfstate-<account_id>`) per account — so the only value
that actually varies per account is the **account ID** itself.

## Decision

**The account dimension lives in git, in `accounts.json`. GitHub secrets hold
only credentials-shaped values. Everything name-shaped derives from the
account ID.**

- `accounts.json` (repo root, read by CI callers via `jq`; deliberately NOT a
  `*.auto.tfvars.json` so terraform never auto-loads it) declares per
  environment: the **account id**, the **env name** (`staging` / `prod` —
  passed to terraform as `TF_VAR_environment`, which selects the deploy-repo
  overlay per the regional-stack `environment` variable), the **enabled
  regions**, per-account **sizing overrides** (base stays in `regions`), the
  **release pin** (`staging: main`, `prod: vX.Y.Z`), and
  **`bootstrap_complete`** — which migrates the `BOOTSTRAP_COMPLETE` repo
  variable into reviewable, per-account data.
- **Role and bucket names derive from `account_id`**:
  `arn:aws:iam::<account_id>:role/gh-tf-apply-platform` and
  `aegis-platform-aws-tfstate-<account_id>`. No per-account secret exists for
  either. Secrets keep only what is genuinely credential-shaped or private
  (PATs, the operator principal, Grafana Cloud values).
- **Workflows become account-parameterized** (W3 branch): the reusable apply
  workflow takes `account_id` + `ref` + regions/overrides; the reaper and
  infra-ops iterate accounts from `accounts.json` instead of assuming the one
  implicit account.

### Recorded gating decisions (locked 2026-06-06/10 — do not re-litigate)

- **Prod always applies under `prod-apply-gated`.** The human-approval
  environment is unconditional for prod — not only when the version gate
  trips. Staging routes to the ungated `staging` environment.
- **The A12 EKS version gate hard-fails prod.** With `gate_blocks=true`
  (the prod caller's setting), a tripped gate FAILS the prod apply — an
  extended-support-priced cluster never reaches prod. Staging is warn-only
  (`gate_blocks=false`) so iteration stays fast.
- **Reaper auto-destroy is ungated but tag-guarded.** The reaper's
  dispatched destroy runs in a dedicated `reaper-destroy` GitHub environment:
  **no required reviewers** (the reaper exists precisely for the
  nobody-present case — a human gate would reduce it to an alert), deployment
  policy = main branch only, and the job **re-verifies in-job** that each
  target cluster carries no `keep` / `ttl-exempt` tag before destroying.
  Human-triggered destroys keep the reviewer-gated `destroy` environment
  unchanged — two environments, two trust subjects on the destroy role, one
  per control model.

## Alternatives considered

- **Per-account GitHub secrets** (`AWS_APPLY_ROLE_ARN_STAGING`, …): rejected —
  unreviewable topology, N×M sprawl, and naming-by-convention is exactly the
  implicit coupling the derive-from-account-id rule removes.
- **GitHub environment variables as the account store:** rejected — same
  write-only problem as secrets, plus environment config is not in git history
  (no review, no rollback, no fork-and-read).
- **A `*.auto.tfvars.json` for accounts:** rejected — terraform would
  auto-load it in every env, but the account dimension is CI **orchestration**
  data (which account to assume into), not terraform input; auto-loading it
  blurs that boundary.
- **Human-gating the reaper destroy:** rejected — the reaper is the L3
  *unattended* backstop (postmortem, 2026-06-06); requiring a reviewer
  reintroduces the presence assumption L3 exists to remove. The tag guard +
  in-job re-verification + main-only deployment policy bound the blast
  radius instead.

## Consequences

- Topology review happens in PRs: adding an account, enabling a region,
  flipping `bootstrap_complete`, bumping the prod pin — all are diffs.
- The reaper and infra-ops must be account-parameterized (W3 branch carries
  this); until that lands they remain single-account.
- `BOOTSTRAP_COMPLETE` (repo variable) is superseded by per-account
  `bootstrap_complete` in `accounts.json`; the variable is removed once the
  W3 callers land.
- New operator-created GitHub environments are prerequisites:
  `reaper-destroy` (no reviewers, main-branch-only) and `staging` (ungated).
- Account IDs become visible in git. Accepted: an account ID is an
  identifier, not a credential (AWS does not treat it as secret); the org
  SCPs + OIDC trust conditions are the actual access control.

## Related

[ADR-01](01-architecture-and-topology.md) ·
[ADR-03](03-delivery-cicd-gitops.md) ·
[ADR-10](10-release-model-build-once-promote-by-digest.md) ·
`docs/postmortems/2026-06-06-eks-extended-support-cost-incident.md` (L3 model)
