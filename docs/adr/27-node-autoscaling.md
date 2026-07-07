# ADR-27: Node autoscaling — close the pending-pods-never-scale gap (#182)

## Status

**Accepted — decided by Bin 2026-07-07: option (a) Karpenter.** Drafted as
Proposed with four options from review finding
[#182](https://github.com/BinHsu/aegis-platform-aws/issues/182) (epic #181);
the operator picked Karpenter the following day. Options (b)–(d) below stand
as the considered alternatives.

**No implementation ships with this ADR's PR.** This record captures the
decision only; the Karpenter install (helm_release + default NodePool /
EC2NodeClass + interruption-queue infra + Pod Identity role, then the
follow-up shrink of the static #183 On-Demand baseline once
Karpenter-provisioned capacity is verified on staging) is follow-up work —
**#182 stays open to track the implementation**.

Numbering: ADR-24 is reserved by in-flight work on another branch; ADR-25/26
are reserved by the epic #167 ownership-inversion work; this record takes 27.

## Context

No autoscaler is installed. The regional stack runs one managed node group with
`min_size = var.node_min`, `max_size = var.node_max`, and `desired_size`
**pinned to `node_min`** (`modules/regional-stack/eks.tf`). Nothing ever raises
`desired_size`, so:

- `node_max` is dead configuration — unreachable capacity.
- Under load, pods queue in `Pending` indefinitely; the cluster silently caps
  at whatever `node_min` provisioned. On-call sees a capacity incident with no
  automatic recovery.

Prior direction exists but stops short of a decision:

- [ADR-08](08-cluster-multi-tenancy.md) names a **dedicated Karpenter
  NodePool** as the first multi-tenancy escape hatch and lists Karpenter in the
  invariant cluster-baseline controller set — but ADR-08 is about *isolation
  tiers*, and Karpenter was never actually installed
  (`docs/runbooks/2026-06-20-dual-region-full-verification.md` A9: "no
  Karpenter — managed SPOT node group only").
- [`docs/tradeoffs.md`](../tradeoffs.md) cites Karpenter as "the ADR-08 escape
  hatch" and explicitly defers EKS Auto Mode as a convenience-vs-control trade
  not taken.

Related but separate: finding #183 (fixed in the same review cycle) diversifies
the Spot node group's instance types and adds an On-Demand baseline node group.
That fix changes *what* the static groups run, not *whether* capacity scales —
this ADR owns the scaling question. Whichever option is chosen below should be
reconciled with the #183 shape (noted per option).

## Decision

### (a) Karpenter — CHOSEN (Bin, 2026-07-07)

Install Karpenter via the regional-stack module (helm_release, same pattern as
the existing controller set), with a default `NodePool` + `EC2NodeClass`:
Graviton (arm64), Spot-preferred with On-Demand fallback, consolidation
enabled.

- **For:** the AWS-recommended EKS autoscaler; pending-pod-driven provisioning
  (no ASG coupling); bin-packing + consolidation actively reduce cost (this
  repo's dominant constraint); native Spot interruption handling and
  spot-to-spot consolidation; `capacity-type` weighting gives
  spot-with-on-demand-fallback — which would *subsume* the #183 static
  On-Demand baseline group (the MNG baseline could then shrink to the minimum
  that hosts Karpenter itself, or move to a tiny static group as AWS guidance
  suggests). ADR-08's escape-hatch ladder (dedicated NodePool per workload)
  becomes real instead of aspirational.
- **Against:** one more controller to operate (IAM role via Pod Identity,
  interruption-queue infra: SQS + EventBridge rules); upgrade cadence; the
  chicken-egg (Karpenter must run on nodes it does not manage — the existing
  MNG serves as that static base, so this is handled, but it is a real
  constraint to document); largest implementation surface of the three install
  options.

## Considered alternatives

### (b) Cluster Autoscaler

Install the Kubernetes Cluster Autoscaler pinned to the existing managed node
group's ASG; it raises/lowers `desired_size` between `min_size` and `max_size`.

- **For:** smallest conceptual change — makes the *existing* `node_max`
  meaningful with one helm_release + one scoped IAM policy; battle-tested;
  no new node-provisioning model to learn.
- **Against:** ASG-granularity scaling (whole instance types per group, no
  bin-packing, no consolidation — cost stays higher than (a)); slower
  scale-out; AWS positions Karpenter as the successor for exactly this repo's
  profile (Spot, cost-driven, heterogeneous types after #183); scaling a
  multi-instance-type Spot ASG works but forfeits Karpenter's per-pod
  instance selection. Does not subsume the #183 baseline group (it would
  simply also scale it if configured, or leave it static).

### (c) EKS Auto Mode

Hand node lifecycle (and the built-in Karpenter) to AWS.

- **For:** zero controllers to operate; interruption handling, consolidation,
  and node patching are AWS's problem; fastest path to "pending pods scale
  nodes".
- **Against:** `docs/tradeoffs.md` already records this as a
  convenience-vs-control trade *not taken*, with "revisit if node-ops toil
  grows" as the trigger — adopting it here re-litigates that entry; per-vCPU
  management premium on top of EC2; less control over AMI/bootstrap
  (relevant to the arm64-clean verification in eks.tf); migrating the existing
  MNG-based stack is a larger structural change than adding a controller.

### (d) Do nothing structural — remove the dead config, document the cap

Set `node_max = node_min` (or drop `node_max`), making the fixed-capacity
posture explicit instead of implied.

- **For:** honest about current behaviour; zero new moving parts; arguably
  adequate for a two-workload portfolio cluster whose sizing is static and
  whose real constraint is cost ceiling, not elasticity.
- **Against:** does not fix the finding's failure scenario (load spike →
  Pending forever); contradicts ADR-08's stated escape-hatch ladder and
  tradeoffs.md's "Karpenter as escape hatch" claim — both would need
  rewording; leaves HPA (workload layer) able to request replicas the node
  layer can never host.

## Rationale for the choice

Karpenter is the direction the repo's own documents already point to (ADR-08
escape hatch, tradeoffs.md), it is the AWS-canonical answer for a Spot-heavy
cost-driven cluster, and it converts the #183 static On-Demand baseline into a
policy (`capacity-type` fallback) rather than a second node group. The agent
recommendation matched; Bin ratified it 2026-07-07.

Implementation scoping (for the follow-up tracked in #182): install in the
regional-stack module behind a variable (default on), keep the existing MNG as
the static base for Karpenter itself, then shrink `node_min` / the #183
On-Demand baseline in a follow-up once Karpenter-provisioned capacity is
verified on staging.

## Consequences

- **Until the follow-up lands** (the state this ADR's PR ships): capacity is
  static at `node_min` (Spot, type-diversified per #183) plus the #183
  On-Demand baseline; `node_max` remains aspirational. #182 stays open.
- **Once Karpenter lands:** pending pods provision nodes (the finding's
  failure scenario closes); the platform takes on one more controller to
  operate — Pod Identity role, SQS + EventBridge interruption infra, upgrade
  cadence; the existing MNG shrinks to the static base that hosts Karpenter;
  the #183 baseline group is re-evaluated against `capacity-type` fallback
  (likely removed); ADR-08's dedicated-NodePool escape hatch becomes real.
- `docs/tradeoffs.md`'s "Karpenter as the escape hatch, unwired" entry and the
  dual-region runbook's "no Karpenter" note become stale at implementation
  time and are updated in the follow-up PR, not here.
