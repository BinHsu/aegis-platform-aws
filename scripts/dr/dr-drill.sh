#!/usr/bin/env bash
# DR drill — region rebuild + cross-region failover evidence.
#
# Tears one region's workload down to nothing and rebuilds it from IaC + git,
# proving the workload is reconstructible. While that region is down, every
# other enabled region is probed continuously — a surviving region serving
# throughout is the cross-region failover evidence. Sequences the phases,
# times each, captures CLI evidence, and writes docs/evidence/DR_REPORT.md.
#
#   Usage:  scripts/dr/dr-drill.sh <region>
#
# DESTRUCTIVE: phase 1 destroys the live EKS cluster in <region>. The script
# requires the operator to type the region name to confirm before it proceeds.
#
# Plan + failure-mode matrix: docs/dr-plan.md

set -euo pipefail

REGION="${1:-}"
[ -n "$REGION" ] || { echo "usage: $0 <region>" >&2; exit 2; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

CLUSTER="aegis-stateless-${REGION}"
EVIDENCE_DIR="docs/evidence"
REPORT="${EVIDENCE_DIR}/DR_REPORT.md"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${EVIDENCE_DIR}/dr-drill-${STAMP}.log"
PROBE_LOG="${EVIDENCE_DIR}/dr-failover-probe-${STAMP}.log"
mkdir -p "$EVIDENCE_DIR"
exec > >(tee -a "$LOG") 2>&1

ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
now() { date -u +%s; }
say() { printf '\n=== %s === %s\n' "$1" "$(ts)"; }
dur() { printf '%dm %ds' $(( ($2 - $1) / 60 )) $(( ($2 - $1) % 60 )); }

# Other regions still enabled in regions.auto.tfvars.json — they must keep
# serving while $REGION is torn down and rebuilt. Empty for a single-region
# deployment, in which case the failover probe is skipped.
SURVIVORS="$(jq -r --arg d "$REGION" \
  '.regions | to_entries[] | select(.value.enabled and .key != $d) | .key' \
  regions.auto.tfvars.json)"
SURVIVOR_ALBS=""   # space-separated "<region>|<alb-host>" tokens
PROBE_PID=""

# Background probe — hits each surviving region's greeter health endpoint
# through its own ALB every 20 s, logging the HTTP status. The greeter.<zone>
# DNS name needs the zone's nameservers to resolve; the ALB hostname is
# globally resolvable, so the probe targets it directly.
probe_survivors() {
  while :; do
    for pair in $SURVIVOR_ALBS; do
      code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 \
        -H 'Host: greeter.aegis-stateless.test' \
        "http://${pair##*|}/healthz" 2>/dev/null || echo ERR)"
      echo "$(ts) ${pair%%|*} ${code}" >> "$PROBE_LOG"
    done
    sleep 20
  done
}

build_failover_section() {
  [ -n "$SURVIVOR_ALBS" ] && [ -s "$PROBE_LOG" ] || return 0
  printf '\n## Cross-region failover\n\n'
  printf 'While `%s` was torn down and rebuilt, every other enabled region was\n' "$CLUSTER"
  printf 'probed every 20 s on the greeter health endpoint, through its own ALB:\n\n'
  printf '| Surviving region | Probes | Healthy (200) |\n|---|---|---|\n'
  for s in $SURVIVORS; do
    t="$(grep -c " ${s} " "$PROBE_LOG" 2>/dev/null || true)"
    o="$(grep -c " ${s} 200$" "$PROBE_LOG" 2>/dev/null || true)"
    printf '| `%s` | %s | %s |\n' "$s" "${t:-0}" "${o:-0}"
  done
  printf '\nA surviving region serving every probe through the drilled region'"'"'s\n'
  printf 'full teardown and rebuild is the redundancy evidence: regional stacks\n'
  printf 'are independent (separate Terraform state, EKS cluster, ArgoCD), so\n'
  printf 'losing one does not affect another. DNS-level failover — Route 53\n'
  printf 'latency records with evaluate-target-health drop the drilled region'"'"'s\n'
  printf 'record when its ALB is gone — is verifiable from an operator machine\n'
  printf 'with `dig @<zone-nameserver> greeter.aegis-stateless.test`.\n'
}

# ---- phase 0 — baseline ---------------------------------------------------
say "PHASE 0 — baseline"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
kubectl get pods -n greeter -o wide
ready="$(kubectl get deploy aegis-greeter -n greeter -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
[ "${ready:-0}" -ge 1 ] || { echo "baseline FAILED — greeter has no ready replicas; aborting" >&2; exit 1; }
echo "baseline OK — greeter readyReplicas=$ready"

# Resolve each surviving region's greeter ALB for the failover probe.
for s in $SURVIVORS; do
  aws eks update-kubeconfig --name "aegis-stateless-$s" --region "$s" --alias "$s" >/dev/null
  host="$(kubectl --context "$s" get ingress aegis-greeter -n greeter \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [ -n "$host" ]; then
    SURVIVOR_ALBS="${SURVIVOR_ALBS} ${s}|${host}"
    echo "survivor $s ALB: $host"
  else
    echo "WARNING: survivor $s has no ALB hostname — not probed" >&2
  fi
done
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
T0="$(now)"; T0_ts="$(ts)"

# ---- confirmation ---------------------------------------------------------
say "CONFIRM"
echo "Phase 1 runs 'make destroy-region REGION=$REGION' — this DESTROYS the"
echo "live EKS cluster '$CLUSTER' and everything in it."
read -r -p "Type the region name ($REGION) to proceed: " confirm
[ "$confirm" = "$REGION" ] || { echo "confirmation mismatch — aborting" >&2; exit 1; }

# ---- failover probe -------------------------------------------------------
if [ -n "$SURVIVOR_ALBS" ]; then
  : > "$PROBE_LOG"
  probe_survivors & PROBE_PID=$!
  trap '[ -n "$PROBE_PID" ] && kill "$PROBE_PID" 2>/dev/null || true' EXIT
  echo "failover probe started (pid $PROBE_PID) → $PROBE_LOG"
fi

# ---- phase 1 — teardown ---------------------------------------------------
say "PHASE 1 — teardown"
make destroy-region REGION="$REGION" AUTO_APPROVE=-auto-approve
T1="$(now)"; T1_ts="$(ts)"

# ---- phase 2 — rebuild ----------------------------------------------------
say "PHASE 2 — rebuild"
make regional-one REGION="$REGION" AUTO_APPROVE=-auto-approve
T2="$(now)"; T2_ts="$(ts)"

# ---- phase 3 — reconverge -------------------------------------------------
say "PHASE 3 — reconverge"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null
echo "waiting for ArgoCD to reconverge the greeter workload (up to 15 min)..."
deadline=$(( $(now) + 900 ))
until r="$(kubectl get deploy aegis-greeter -n greeter -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"; [ "${r:-0}" -ge 1 ]; do
  [ "$(now)" -lt "$deadline" ] || { echo "reconverge TIMED OUT after 15 min" >&2; exit 1; }
  sleep 15
done
kubectl get pods -n greeter -o wide
T3="$(now)"; T3_ts="$(ts)"

# stop the failover probe — the probe log is complete from here
if [ -n "$PROBE_PID" ]; then kill "$PROBE_PID" 2>/dev/null || true; PROBE_PID=""; fi

# ---- phase 4 — report -----------------------------------------------------
say "PHASE 4 — report"
TEARDOWN="$(dur "$T0" "$T1")"
REBUILD="$(dur "$T1" "$T2")"
RECONVERGE="$(dur "$T2" "$T3")"
RTO="$(dur "$T1" "$T3")"
FAILOVER_SECTION="$(build_failover_section)"

cat > "$REPORT" <<EOF
# DR drill report — region rebuild

> Generated by \`scripts/dr/dr-drill.sh $REGION\` on $(ts).
> Plan + failure-mode matrix: [\`../dr-plan.md\`](../dr-plan.md).

## Result

| Phase | From → to | Duration |
|---|---|---|
| 0 — baseline | — ($T0_ts) | — |
| 1 — teardown ($CLUSTER destroyed) | $T0_ts → $T1_ts | $TEARDOWN |
| 2 — rebuild (Terraform re-apply) | $T1_ts → $T2_ts | $REBUILD |
| 3 — reconverge (ArgoCD syncs from git) | $T2_ts → $T3_ts | $RECONVERGE |
| **Measured cold-rebuild RTO** (region down → workload back) | $T1_ts → $T3_ts | **$RTO** |

The workload was reconstructed from Terraform state + git with no manual
intervention beyond running this script. Terraform state is the source of
truth; ArgoCD converged the cluster from zero.
${FAILOVER_SECTION}

## Grafana evidence — capture manually

The live dashboard is not durable evidence (the cluster is torn down after the
demo; Grafana Cloud's free tier retains data ~14 days). Capture it now, while
the drill window is still queryable:

1. Open the \`aegis-greeter-overview\` dashboard.
2. Set the time range to **$T0_ts → $(ts)**.
3. Screenshot the **Pod readiness** panel (and **Node CPU / Node memory**) —
   they show the drilled region's pods/nodes drop at teardown, the flat gap
   through the rebuild, and the recovery at reconverge. Request-rate / latency
   panels need live traffic — without a load generator they stay flat.
4. Save the screenshots into this directory (e.g. \`grafana-dr-curve.png\` for
   the DR curve, \`grafana-dr-multi-region.png\` for the per-region view) and
   commit them.

## CLI log

Failover probe samples: \`$(basename "$PROBE_LOG")\` — committed alongside this
report (timestamps + HTTP codes only). The full phase-by-phase Terraform CLI
log (\`$(basename "$LOG")\`) is kept operator-local — it carries
account-specific ARNs and is gitignored.
EOF

say "DONE — measured cold-rebuild RTO $RTO"
echo "report: $REPORT"
echo "log:    $LOG"
echo "Next: capture the Grafana screenshot per the report, then commit docs/evidence/."
