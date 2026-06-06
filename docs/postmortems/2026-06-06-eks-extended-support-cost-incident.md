# Postmortem: June 2026 EKS Extended-Support Cost Incident

**Status:** Closed — offending cluster destroyed 2026-06-06 05:31:28 UTC
(CI run 27053659835, "Destroy complete! Resources: 78 destroyed").
`aws eks list-clusters` (prod, eu-central-1) now returns empty.

**Severity:** Cost (budget breach). No availability or data impact.
**Account:** prod `506221082337`, region eu-central-1.
**Author:** incident review, 2026-06-06.
**Detection:** AWS Budgets email alarm (the sole automated guardrail that fired).

---

## 1. Summary

A v1.30 EKS cluster (`aegis-platform-eu-central-1`, terraform `regional` env) stood
in prod for ~3 days and pushed the org over its ~$30 monthly budget. Two compounding
faults:

1. **Cost was 6x the apply-time estimate.** EKS v1.30 is past standard support, so AWS
   billed `EUC1-AmazonEKS-Hours:extendedSupport` ($0.50/hr) **stacked on**
   `:perCluster` ($0.10/hr) = **$0.60/hr**. The apply estimate assumed the $0.10 base.
   **83% of EKS spend was the version penalty.**
2. **The cluster was never torn down.** A `helm_release.kyverno` hang failed the apply
   *after* the cluster was already created (an orphan behind a red apply), and on
   2026-06-03 the same hang blocked the only `destroy` attempt before it reached the
   cluster. It then ran 24/7 until 2026-06-06.

The budget alarm caught it at ~$29 actual. Left to 2026-06-30 the trajectory was
**~$400** for a single verify stack.

### Cost at a glance (UnblendedCost, current-month estimated, settles upward)

| Scope | MTD $ |
|---|---|
| Org total (incl. tax) | ~35.5 |
| prod `506221082337` (incident) | 27.88 |
| staging `251774439261` (sunk, already torn down) | 6.70 |
| EKS control plane (all prod) | 18.31 |
| — of which `:extendedSupport` penalty | **15.26 (83%)** |
| — of which `:perCluster` base | 3.05 |

EKS billed 30.5 cluster-hours over the window at $0.60/hr (exact 5:1 ext:base ratio
every single day — the smoking gun for the version penalty).

### Impact & detection/response metrics

- **Impact:** cost only (~$22 incident-attributable burn). **No availability, data, or
  security impact**; single account (prod `506221082337`), single region. Not pursuing an
  AWS credit — documented as sunk.
- **TTD (time to detect):** ~24h machine / ~36h human. Cluster created 2026-06-04 17:04
  UTC; the org **daily** budget (`aegis-daily-usd10`) tripped on 06-05 when daily spend
  crossed $10; the operator noticed the email ~06-06 morning. **Detection latency was the
  real weakness — not resolution.**
- **TTR (time to resolve):** ~minutes once acted on. The successful CI destroy ran
  05:18→05:31 UTC (cluster gone in 2m17s). The cost driver is the ~2 days the stack sat
  *before* detection, not the teardown itself.

---

## 2. Timeline (UTC)

| When | Source | Event |
|---|---|---|
| 06-03 12:14 | infra-apply 26884025185 | Last clean apply on main (no cluster). |
| 06-03 16:28–17:11 | infra-apply 26898452649 | Apply on main. Cluster #1 created; apply **FAILED 17:11** on kyverno helm "timed out waiting for the condition". **Cluster orphaned behind a red apply.** |
| 06-03 (day) | Cost Explorer | First EKS charge $0.95 (ext $0.79 + base $0.16). |
| 06-03 17:55–18:01 | infra-ops 26903044359 (destroy-region, main) | **Teardown attempt #1.** kyverno helm destroy hung 5 min → "timed out waiting for the condition" → aborted **before reaching `aws_eks_cluster`**. Cluster survived. |
| 06-04 16:55–17:07 | infra-apply 26966535081 (main) | Re-apply. `aws_eks_cluster` created 16:56→17:04 (7m27s). Apply **FAILED again** on the same kyverno timeout. Cluster #2 left standing (ran to 06-06). |
| 06-04 (day) | Cost Explorer | EKS $4.16 (ext $3.47 + base $0.69). |
| 06-05 (day) | Cost Explorer | EKS $13.20 (ext $11.00 + base $2.20) — peak, full 24h. |
| 06-06 ~early | Operator inbox | **AWS Budgets email noticed** — detection. |
| 06-06 05:18–05:19 | infra-ops 27053579376 (destroy-region, **feature branch**) | **Teardown attempt #2.** FAILED at OIDC: `sts:AssumeRoleWithWebIdentity` denied — `gh-tf-apply-platform` trust restricts to `refs/heads/main`. Never reached terraform. |
| 06-06 (pre-destroy) | operator + Claude | Removed 11 in-cluster resources (kyverno/argocd/crossplane/ACK/alb-controller/external-dns + namespaces/secret) from `regional/eu-central-1` state via `terraform state rm`, so destroy would not touch the k8s API. |
| 06-06 05:22–05:31 | infra-ops 27053659835 (destroy-region, **main**) | **Teardown attempt #3 — SUCCESS.** Cluster destroyed in 2m17s; **78 resources destroyed** 05:31:37. Incident closed. |

---

## 3. Root cause

**Primary cost driver:** a v1.30 EKS control plane at **$0.60/hr** (extended-support
$0.50 stacked on perCluster $0.10) running ~3 days in prod. The apply-time estimate
modelled the $0.10 base, so the bill ran 6x the estimate — the "estimate-low / bill-high"
mechanism the operator flagged.

**Why it persisted — the teardown chain failed five times:**

1. 06-03 apply created the cluster then failed on kyverno helm → **orphan behind a red apply**.
2. 06-03 destroy hung on the same kyverno helm and aborted **before** `aws_eks_cluster` → cluster survived its only teardown.
3. 06-04 apply repeated the pattern → second orphan.
4. 06-06 feature-branch destroy denied at OIDC (trust = main-only) → could not self-destroy.
5. 06-06 main destroy finally succeeded.

**The common failure node is the kyverno `helm_release`** — it hangs on *both* lifecycle
sides (orphans the cluster on apply, blocks the cluster on destroy).

---

## 4. Why the guardrails did not stop it

The system has two guardrail layers: **(A) operator-discipline** (CLAUDE.md rules,
memory conventions) and **(B) machine-enforced** (automation that blocks/acts without a
human). Almost every guardrail here was (A)-only. The **only (B)-layer guardrail in the
entire system was the budget alarm — which is exactly why it was the only one that fired.**

| # | Guardrail | Layer | Outcome | Verdict |
|---|---|---|---|---|
| G1 | Budget alarm (AWS Budgets → SNS → email) | **B** | **Fired, caught it at ~$29** | ✅ Worked. The backstop. |
| G2 | "Destroy partial stack on failed apply" (CLAUDE.md rule n) | A | Not executed | ❌ Shallow — prose only, no auto-destroy on red apply |
| G3 | "Apply-then-destroy / tear down after verify" (cost memory) | A | Not executed (left for 06-10 resume) | ❌ Shallow — no TTL reaper / session-end gate |
| G4 | Apply-time hourly cost estimate | A | Underestimated 6x | ❌ Not considered — no extended-support surcharge in the model |
| G5 | kyverno helm lifecycle robustness | — | Hung on apply + destroy | ❌ Not considered (operational dimension) |
| G6 | OIDC teardown access from any ref | B | Blocked the destroy | ⚠️ Backfired — security control with no teardown carve-out |
| G7 | CI green-light discipline (CLAUDE.md rule m) | A | Did not catch the orphan | ❌ Pipeline-exit signal, decoupled from cloud cost/state (below) |

### G2 / G3 — "green-light discipline not executed": **compliance vs scope, split by event**

Both disciplines exist in writing — rule (n) literally says *"On failure, destroy the
partial stack before iterating — never leave a half-applied stack running,"* and the
cost-control memory mandates apply-then-destroy. The accountability splits by event:

- **Failed applies (06-03, 06-04) — execution-side violation of an adequately-broad
  rule.** Rule (n) names this exact case and prescribes the exact remedy ("destroy the
  partial stack before iterating"). It was not followed: 06-04 re-applied (a second
  orphan) instead of destroying first, and the run was left red. The rule was wide
  enough; compliance failed.
- **Failed destroy (06-03) — rule written too narrow.** Rule (m) triggers "after every
  git **push**" — a manual `workflow_dispatch` destroy is not a push, so it never fired.
  Rule (n) triggers on runs that "**provision** billable resources" — a destroy
  *de*-provisions, so its trigger excludes it, even though a *failed* destroy = still
  billing = exactly (n)'s concern. The trigger phrasing missed a dispatched,
  cost-reducing-but-failed run.

### G7 — why CI green/red did not catch it

CI green/red is a **pipeline exit-code signal, decoupled from cloud cost/state**. A red
`terraform apply`/`destroy` is the *worst* case — red pipeline **and** live billable
resources — yet "red" carries no cost semantics and nothing reconciles it. Worse, rule
(m)'s remedy ("fix root cause, re-push, until green") applied to a failed apply means
*re-applying* — which created the second orphan, not removed the first.

**Verdict (all of A2/G2/G3/G7): the disciplines are agent-presence-dependent.** Even with
perfect compliance, (m)/(n) need an agent present to poll and act; trigger-and-end-session
= nothing reconciles. The only presence-independent guardrail was the budget alarm. This
is why the fixes below lower these into machine enforcement (terraform guard, CI gate,
TTL reaper, Stop-hook) with one shared shape: **default-deny + explicit human override
token + auditable.**

### G5 — "why kyverno collapsed": **operational lifecycle not considered**

The policy *content* was carefully designed (the module file is dense with intent). The
helm *lifecycle* was not:

- `helm_release.kyverno` sets **no `wait`** (defaults to `true`), **no `timeout`**
  (defaults to 300s), **no `atomic`**. So helm blocks on readiness (apply) and on
  deletion (destroy), failing at 5 min either way.
- **Apply hang:** on a fresh cluster the nodes were NotReady because the CNI/vpc-cni
  managed addons were not installed (fixed only afterwards in #20 / `b02d3f4`). Kyverno
  pods could not schedule → helm `wait` timed out → apply failed **with the cluster
  already created and billing**. `depends_on = [module.eks]` guarantees the cluster
  *exists*, not that nodes are *Ready* — a missing layer in the dependency model.
- **Destroy hang:** kyverno's admission webhooks + finalizers deadlock its own helm
  uninstall; with `wait=true` and no `disable_webhooks` / pre-destroy cleanup, the
  uninstall times out before terraform reaches `aws_eks_cluster`.
- The code self-documents the gap: *"⚠️ implemented, E2E PENDING platform bootstrap …
  have NOT run against a live cluster."* The fragility was known-untested.

**Verdict: not considered (operational/lifecycle dimension).** Functional correctness
was modelled; the create/destroy failure surface of a webhook-based helm release was not.

### G6 — OIDC: a working control that backfired for teardown

The `gh-tf-apply-platform` trust policy admits only `repo:BinHsu/aegis-platform-aws:ref:refs/heads/main`.
Correct for apply hygiene, but it means **feature-branch work cannot tear down its own
verify stack** — adding failed attempt #2 and a delay to remediation.

### Detection note — the alarm that fired was the org-level **daily** budget

Budget inventory at incident time:

| Account | Budget | Limit |
|---|---|---|
| management `186052668286` (payer) | `aegis-daily-usd10` | $10 / **day** |
| management `186052668286` (payer) | `aegis-monthly-usd30` | $30 / month |
| prod `506221082337` | `aegis-platform-aws-monthly` | $25 / month |
| staging / shared / log-archive / member | **none** | — |

The detection win was the **org-level daily budget** (`aegis-daily-usd10`): on 06-05 the
org burned ~$15 in one day, blowing past $10/day, so the daily budget tripped fast —
daily granularity beats a monthly forecast's multi-day extrapolation lag. The prod
`$25/month` budget (warn $10, FORECASTED > 32% = $8, ACTUAL > 100% = $25; SNS email
**confirmed**, account aged >38 days so forecasting active, forecast $11.68 > $8) also
fired but more slowly. **The budget alarm is the win of this incident. The gap is
coverage: member accounts (staging, shared, log-archive) have no per-account budget, so
spend there is only visible through the payer roll-up, not attributed or alarmed at
source.**

---

## 5. What went well

- The budget alarm fired and bounded the loss to ~$29 instead of ~$400. Build it
  everywhere (see Action A1).
- The `terraform state rm` of in-cluster resources before destroy permanently bypassed
  the kyverno teardown deadlock — clean 78-resource destroy in one pass.
- Cost Explorer usage-type breakdown localized the root cause (extended support) fast.

---

## 6. Action items

Ordered by leverage. The theme: **lower the prose disciplines into machine-enforced
depth — make them all look like the budget alarm (G1).**

**A4 is the keystone** (now done): it is the cheapest fix and it *unlocks* the others —
without a teardown that doesn't deadlock, the L3 reaper's auto-destroy (A5) and the CI
self-reap (A6) would just re-trigger the original hang. Sequence anything else after A4.

### Prevention model — three layers, orthogonal axes, each with a human override

Defense-in-depth that **caps blast radius** (it does not claim zero — it bounds loss).
The layers sit on orthogonal axes, so each closes the next's blind spot:

| Layer | Axis | Catches | Override | Status |
|---|---|---|---|---|
| **L1 — prevent at apply time** | configuration | A bad/aging version can't create an extended-support cluster without a human approving: explicit pin + terraform `check` warning (A3) + CI required-approval gate (A3b). | bump the pin / approve the gated env | ✅ A3 live, A3b static |
| **L2 — attended runtime catch** | presence (is a human watching?) | While a human is in the loop, an agent cannot silently leave a cloud-mutating run unreconciled at session end: PreToolUse sentinel + Stop hook (A8). | `.abandon-ok` marker | ✅ implemented (this PR) |
| **L3 — unattended backstop** | resource lifetime + $ (presence-independent) | Anything that gets past L1/L2 with no human present: TTL reaper caps any orphan to ≤N h (A5); the budget alarm/actions (G1/A9) catch by *bill* whatever the reaper's scope doesn't know about (untagged, non-EKS, new service). | `keep`/`ttl-exempt` tag; budget approval mode | ✅ reaper (this PR); budget live |

L2 covers "human present, walking away"; L3 covers "human gone, nothing reconciled" —
together they seal both the **attended** and **unattended** paths. L3 is the only
presence-independent layer, so it is the one that generalizes safely org-wide; L2 (an
agent-lifecycle control) stays project-scoped and specific. The budget alarm is the
final catch-all because it watches the symptom (spend), not the cause — it needs no prior
knowledge that a resource exists (it is what fired in this incident).

| ID | Action | Addresses | Priority |
|---|---|---|---|
| A1 | **Per-account budget propagation — DEFERRED (operator decision 2026-06-06).** At 4–6 accounts the payer-level org budgets (`aegis-daily-usd10` + `aegis-monthly-usd30`) are a sufficient backstop; they caught this incident. Per-account budgets add only spend *attribution*, and at this scale attribution is a single Cost Explorer `group-by LINKED_ACCOUNT` query. Revisit if the account count grows or chargeback is needed. The portable lesson stands: **daily-granularity budgets beat monthly-forecast lag** — keep the daily one. | G1 | Deferred |
| A2 | **Add AWS Cost Anomaly Detection** on the EKS / extendedSupport usage type — service-dimension signal that flags an unexpected `:extendedSupport` line even within a daily budget. Complements A1 (a daily budget catches *total* spend; anomaly detection catches a *new shape* of spend). | Detection precision | P1 |
| A3 | **DONE 2026-06-06 (validated).** Explicit human-bumped `cluster_version` + plan-time `check` that *warns* when aging out (detail §7); default `1.30`→`1.35`. `terraform validate` + scratch fail/pass proven. | G4, primary cost driver | ✅ Done |
| A3b | **DONE 2026-06-06 (static).** CI `version-gate` job → whole-wave required-approval environment for apply-regional (detail §7a). `actionlint` clean; **not live-verified** (needs repo Environments + main push). | G4 / G7, machine gate | ✅ Static |
| A4 | **DONE 2026-06-06 (static).** Two-part: (1) `wait = false` + `timeout = 300` on both kyverno helm releases so the uninstall stops blocking terraform; (2) **root-cause** — a destroy-time `null_resource` (`depends_on` kyverno → torn down first) that `kubectl delete`s kyverno's validating/mutating webhookconfigurations *before* the uninstall, breaking the deadlock at its source. Fully best-effort (zero apply risk; falls back to wait=false if kubectl/creds absent). Apply-time NotReady-nodes hang was separate, already fixed by CNI addons (`eks.tf` #20). `disable_webhooks` was **rejected** — it touches the install path (could break a real apply) and is redundant with the null_resource. `terraform validate` clean; **live verification deferred to the planned 6/12 teardown.** Unblocks A5 auto-destroy + A6. | G5 | ✅ Static |
| A5 | **DONE 2026-06-06 (static).** TTL reaper `.github/workflows/ttl-reaper.yml` — scheduled (every 4h), scans EKS clusters older than `TTL_HOURS` (default 8), **presence-independent**. Default **alert-only** (opens an issue + warns); set `REAPER_AUTODESTROY=true` after A4 to auto-dispatch destroy-region. Override: `ttl-exempt`/`keep` tag. `actionlint` clean + scan logic run against live (empty) API; **not live-verified on a real over-TTL cluster**. | G3, agent-presence gap | ✅ Static |
| A6 | **CI self-reap on failed apply + escalate on failed destroy.** `if: failure()` cleanup on the apply job so a red apply cannot leave billable resources (override: human-set `ALLOW_PARTIAL_APPLY=true`); `if: failure()` SNS/issue on destroy so a failed teardown alerts without anyone polling. **Caveat:** auto-destroy is safe only for ephemeral clusters — for stateful prod, escalate, don't destroy; and the reap must avoid the kyverno hang (depends on A4). | G2, G7 | P1 |
| A7 | **Teardown-only OIDC subject** (or a `gh-tf-destroy-*` role) admitting feature branches for `destroy-region` only, so verify stacks can self-destroy. **Recurring friction, not nice-to-have:** the main-only OIDC trust caused this incident's failed teardown attempt #2 and lengthened MTTR, and it re-bites every time a feature-branch verify stack needs tearing down. | G6 | **P1** |
| A8 | **DONE 2026-06-06 (validated, project-scoped).** Default-deny-on-red agent contract enforced by a PreToolUse sentinel (`.claude/hooks/cloud-mutation-sentinel.sh`) + Stop gate (`cloud-mutation-stop-gate.sh`), wired in `.claude/settings.json`. A cloud-mutating Bash command writes a sentinel; the Stop hook blocks session end until it is cleared (drive to green / reap) or a human drops `.abandon-ok`. 6/6 unit tests pass. Scoped to this repo (agent-presence layer); the unattended path is A5's job. Loud-nudge-not-wall (allows through on re-stop to avoid trapping unattended sessions). | G7, agent-presence gap | ✅ Done |
| A9 | **Escalate the budget alarm from email → action (AWS Budget Actions).** On breach, apply a restrictive policy / stop resources. **Deliberately P2 — not "no time."** The postmortem's "machine acts" thesis is realized by L1/L2/L3 acting on *scoped, ephemeral* resources. The budget layer is the **worst** place to apply it: an automatic Budget Action in the payer account has org-wide blast radius (a restrictive SCP can freeze prod), so the only safe form is *approval-required* — which is barely more than the email that already works. High-blast-radius autonomy + low marginal value over the existing alarm = P2. | G1 depth | P2 (rationale, not backlog) |
| A10 | **DONE 2026-06-06.** Migrated the CI/Makefile security scanner from the **EOL tfsec to trivy** — tfsec's HCL parser rejects the TF 1.5 `check` block that L1 relies on. `trivy config … --tf-exclude-downloaded-modules --skip-dirs '**/.terraform/**' --severity MEDIUM,HIGH,CRITICAL` (install-tools.sh pins trivy 0.71.0, SHA256-verified). Our code is clean at MEDIUM+; 2 pre-existing LOW S3-logging findings are informational. Inline `#tfsec:ignore` comments are now no-ops (trivy uses `#trivy:ignore:<AVD-ID>`) but harmless — none of those rules fire at the gate severity; converting them is a cosmetic follow-up. | L1 enablement | ✅ Done |
| A11 | **DECISION (seam, not a footnote): the TTL reaper is EKS-only.** It scans `aws eks list-clusters`; an RDS instance, an idle NAT gateway, or a runaway Fargate task is **invisible to L3's reaper** and falls only to the budget alarm (which catches by $ symptom, slowly). **Chosen v1 scope = EKS-only** (the incident's driver + the $0.60/hr control-plane is the worst leak). **Open decision:** generalize the reaper to a **tag-based sweep over all billable types** (find anything tagged ephemeral past TTL) vs. accept "EKS reaped, everything else on budget." Code deferred — multi-API (RDS/EC2/ECS/ELB) and unverifiable without live resources; not landing it blind. | G3 coverage | P1 (decision) / P2 (code) |
| A12 | **DECISION (seam): version-age detection has two sources of truth** — the L1 terraform `check` (A3) and the CI gate's AWS-CLI re-derivation (A3b). They will drift. **Single-source target:** the CI gate parses `terraform show -json` `.checks[]` so the terraform `check` is the only detector. **Why duplicated initially (conscious carrying cost):** the single-source gate must run a full `terraform plan` in CI (all vars/secrets wired into the gate job) — heavier; the CLI re-derivation was the lightweight v1. **Pay-down trigger:** when the gate job is next touched, or before any second `check`-based gate is added. Code deferred here — it changes the gate substantially and is only verifiable on a `main` push; landing it broken is worse than the duplication. | G4 / G7 | P1 (decision) / P2 (code) |

---

## 7. Prevention detail — EKS version guard (A3), and why it is a storm in real production

The root cause was a **hardcoded** `cluster_version = "1.30"` in
`terraform/modules/regional-stack/variables.tf` — a literal whose standard support
ended **2025-07-23**, so every apply produced an extended-support cluster ($0.60/hr).

**Design decision (2026-06-06):** keep the version an *explicit, human-bumped literal*
(aligned with the project's explicit-over-implicit principle) and add a plan-time
`check` block that **warns** — does not block — when the pinned version is past (or
near) the end of standard support. Auto-resolving to "latest GA" was rejected: it would
let the version drift on a routine apply, which in production *is* the upgrade storm
(below).

**Status: implemented + validated 2026-06-06** (branch `fix/eks-cost-guard`).
`terraform validate` passes; a scratch project proved the check resolves to
`fail` for 1.30 and `pass` for 1.35, and that `terraform show -json` exposes the
result as `.checks[].status` at *plan* time (needed by the CI gate).

```hcl
# variables.tf — version is an EXPLICIT literal a human bumps deliberately.
variable "cluster_version" {
  type    = string
  default = "1.35" # was "1.30" — standard support ended 2025-07-23.
}

# eks-version-guard.tf — resolve support dates from AWS, then WARN
# (terraform `check` asserts are non-blocking) when the pin is aging out.
data "aws_eks_cluster_versions" "support_status" {
  include_all = true # include versions already past standard support
}

locals {
  # `cluster_versions_only` is an OUTPUT (version strings), NOT a server-side
  # filter — so match the pinned version in HCL.
  _eks_match = [
    for v in data.aws_eks_cluster_versions.support_status.cluster_versions :
    v if v.cluster_version == var.cluster_version
  ]
  _eks_eos = length(local._eks_match) > 0 ? local._eks_match[0].end_of_standard_support_date : null
}

check "eks_version_in_standard_support" {
  assert {
    # plantimestamp() is known at PLAN time; timestamp() is not (it would leave
    # the check "unknown" until apply and the CI gate blind).
    condition = local._eks_eos != null ? timecmp(plantimestamp(), local._eks_eos) < 0 : false
    error_message = format(
      "EKS %s is in/near extended support ($0.60/hr vs $0.10/hr base) - end of standard support: %s. Bump var.cluster_version.",
      var.cluster_version, coalesce(local._eks_eos, "unknown/unlisted"),
    )
  }
}
```

A `check` block surfaces a **warning** on every plan/apply (local and CI) once the date
passes — it informs without blocking an emergency apply. The guard detects; it never
acts. Three traps surfaced only by *running* it (not by reading the docs): (1)
`cluster_versions_only` is an output, not a filter; (2) `timestamp()` is unknown at plan
time — use `plantimestamp()`; (3) a naive `awk '/default/'` matched a comment containing
the word "default" — anchor on `^[[:space:]]*default[[:space:]]*=`.

### 7a. CI approval gate (whole-wave single approval)

A non-blocking warning is layer-(A) — easy to ignore in CI logs. The CI pipeline turns
it into a layer-(B) **required-approval gate**: a `version-gate` job checks the pinned
version's standard-support date (AWS CLI); if it has aged out, `apply-regional` routes
through a required-reviewer environment so a human must approve before a cluster bills at
$0.60/hr.

```yaml
# infra-apply.yml
version-gate:
  needs: setup
  outputs: { gate: ${{ steps.check.outputs.gate }} }
  steps:
    - { uses: actions/checkout@v6 }
    - uses: aws-actions/configure-aws-credentials@v6
      with: { role-to-assume: ${{ secrets.AWS_INFRA_APPLY_ROLE_ARN }}, aws-region: ${{ env.AWS_REGION }} }
    - id: check
      run: |
        ver=$(awk '/variable "cluster_version"/{f=1} f&&/^[[:space:]]*default[[:space:]]*=/{gsub(/[",]/,"",$3);print $3;exit}' \
          terraform/modules/regional-stack/variables.tf)
        eos=$(aws eks describe-cluster-versions \
          --query "clusterVersions[?clusterVersion=='${ver}'].endOfStandardSupportDate | [0]" --output text)
        gate=false
        if [ "$eos" = "None" ] || [ -z "$eos" ]; then gate=true
        elif [ "$(date -u +%s)" -ge "$(date -u -d "$eos" +%s)" ]; then gate=true; fi
        echo "gate=$gate" >> "$GITHUB_OUTPUT"

apply-regional:
  needs: [setup, apply-platform, version-gate]
  # whole-wave single approval: any aging version → the entire apply wave waits
  # on one reviewer (matrix cells cannot each carry a per-cell environment).
  environment: ${{ needs.version-gate.outputs.gate == 'true' && 'prod-apply-gated' || 'prod-apply' }}
```

**Status: implemented + statically validated, NOT live-verified.** `actionlint` (pinned
`rhysd/actionlint:1.7.7`) passes; the `awk` extraction and the AWS query shape were run
against the live API. It is **not** end-to-end proven because GitHub Environment required
reviewers need repo Settings → Environments (`prod-apply-gated` with reviewers,
`prod-apply` without) and the gate only exercises on a `main` push (OIDC trust is
main-only). Two known limits: (1) **whole-wave, not per-region** — GitHub matrix cells
cannot each select an environment, so any aging version gates the whole wave (one
approval releases it); (2) detection is **duplicated** (CLI here vs the terraform `check`
in the module) — a single-source variant would parse `terraform show -json` `.checks[]`
from a full plan.

**Why this is cheap here but a storm in real production:**

This fix is safe in *this* repo only because clusters are **ephemeral**
(verify-then-destroy). Reacting to the warning here = `destroy` + `apply` at the new
pinned version = a brand-new cluster, **zero in-place upgrade risk**.

In a **long-lived production** cluster the same warning triggers a **control-plane
version upgrade** — a different, high-risk change class:

- Removed/deprecated Kubernetes APIs can break running workloads on cutover.
- Every addon and helm chart (kyverno, argocd, ACK, crossplane, alb-controller) must
  support the target version — a 5-minor jump like 1.30→1.35 is not a free bump.
- Nodes must be rolled (drain/replace).

That is **not** a casual `var.cluster_version` edit — it needs API-deprecation scanning
(`kubent` / `pluto`), a staged or blue/green cluster cutover, and a rollback plan. The
cost guard and the upgrade are deliberately **decoupled**: the guard says *when* a bump
is due (cheap, automated, non-blocking); *whether and how* to absorb the upgrade stays a
human production decision. Coupling them — the rejected auto-latest option — is exactly
how a routine apply becomes an outage.

### 7b. Layer 2 as-built — attended runtime catch (Stop hook)

Two hooks wired in `aegis-platform-aws/.claude/settings.json` (committed, so they travel
with the repo):

- **PreToolUse(Bash)** `.claude/hooks/cloud-mutation-sentinel.sh` — when the agent runs a
  cloud-mutating command (`terraform apply|destroy`, `gh workflow run … apply|destroy`,
  `make cloud-up|down`), it appends a line to `.claude/.cloud-mutation-open` (gitignored).
  It never blocks the command — it only records.
- **Stop** `.claude/hooks/cloud-mutation-stop-gate.sh` — on session end, if the sentinel
  exists and `.claude/.abandon-ok` does not, it returns `{"decision":"block","reason":…}`
  forcing the agent to keep working (drive to green / tear down, then `rm` the sentinel).
  Explicit human override: `touch .claude/.abandon-ok`.

**Loud nudge, not a wall.** On a re-stop (`stop_hook_active == true`) the gate allows
through, so it cannot trap an unattended session in a loop. That is deliberate: L2 only
covers "a human is present, about to walk away." The hard, presence-independent stop for
the unattended case is L3 (the reaper).

**Coverage caveat (honest).** The hook only fires when a Claude Code session runs *in*
`aegis-platform-aws`. Cloud mutations initiated from another repo's session — e.g. driving
the platform state from an `aegis-enclave` session, which is exactly how this incident's
remediation ran — are **not** caught by L2. That gap is by design covered by L3, which is
presence- and repo-independent (it watches the cloud, not the agent). Promoting L2 to
global was considered and rejected (it spreads the agent-presence dependency and risks
false-trap / false-release / override-reflex without becoming presence-independent).

### 7c. Layer 3 as-built — unattended backstop (TTL reaper)

`.github/workflows/ttl-reaper.yml` — a scheduled workflow (every 4h + `workflow_dispatch`)
that assumes the apply OIDC role, scans EKS clusters in the enabled regions, and flags any
older than `TTL_HOURS` (default 8) that is not tagged `ttl-exempt`/`keep`. Presence- and
repo-independent: it bounds a leaked cluster's life to ≤ TTL+4h even if every session is
gone. Default is **alert-only** (opens a GitHub issue + `::warning::`); set repo variable
`REAPER_AUTODESTROY=true` (after A4 is live-verified) to auto-dispatch `destroy-region`.

### 7d. Validation matrix — what is proven, to what depth

| Item | Validation | Live-verified? |
|---|---|---|
| L1 module guard (A3) | `terraform validate` + scratch project: 1.30→`fail`, 1.35→`pass`, `.checks[]` resolves at plan | ✅ yes |
| L1 CI gate (A3b) | `actionlint` clean; `awk` + AWS query run against live API | ❌ needs repo Environments + `main` push |
| L2 hook (A8) | 6/6 unit tests (benign/apply/destroy/override/re-stop); `jq` schema | ⚠️ unit only — fires only in a platform-aws session after `/hooks` reload |
| L3 reaper (A5) | `actionlint` clean; scan logic run against live (empty) API | ❌ needs a real over-TTL cluster |
| A4 kyverno destroy fix | `terraform validate` clean | ❌ needs a real teardown |
| Budget alarm (G1/L3) | fired in this incident | ✅ yes (production) |

The pattern: the parts that could be validated locally are live-proven; the parts that
require GitHub Environment settings, a `main` push, or a real cluster are
static/unit-validated and explicitly flagged for a live pass.

## 8. Data gaps / caveats

- **CloudTrail principal forensics unavailable** — `cloudtrail lookup-events` was
  permission-denied at the tooling layer; actor attribution was reconstructed from
  GitHub Actions history (authoritative for the CI path: all creates + teardowns ran via
  the `gh-tf-apply-platform` OIDC role — CI, not ad-hoc human SSO).
- **06-06 cost shows $0** (current day not yet materialized); add ~$3–4 for 06-06
  pre-teardown hours when it finalizes.
- All figures are UnblendedCost, current-month **Estimated=true** — they settle upward
  over hours (prod MTD read $21.2 at ~07:05, $27.9 at ~07:35 the same morning).
