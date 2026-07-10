#!/usr/bin/env bash
# Karpenter quiesce + orphan-EC2-by-tag fail-safe — ensures Karpenter-launched
# EC2 instances are gone (or forcibly terminated) BEFORE `terraform destroy`
# tears down the cluster/VPC that owns them.
#
# WHY (#200 — successor to aegis-landing-zone-aws#151, Incident 33): Karpenter's
# controller (helm_release.karpenter, karpenter.tf) is installed with
# `wait = false` deliberately — same teardown-safety posture as kyverno.tf /
# argo-rollouts.tf, so a `helm uninstall` can never block `terraform destroy`
# reaching the EKS cluster delete (the 2026-06-06 billing-cluster incident
# shape). The trade-off: the controller can be torn down before it has gracefully
# drained + terminated its own EC2 fleet. When that happens the instances become
# orphans — nothing left in the account watches them, and they keep billing
# after the cluster is gone (Incident 33: 2x t3.medium ran ~60min past their
# expected termination, ~10+ min added to teardown from the resulting slow ENI
# cleanup).
#
# PATTERN: mirrors the ALB/SG reaper backstop (pre-destroy.sh + the concurrent
# SG reaper in infra-ops.yml) — over-clean, never under-clean; log exactly what
# was reaped; never let a wedged step hang the destroy job. Every step below is
# best-effort and time-boxed: a stuck quiesce degrades to "terminate by tag"
# instead of blocking teardown indefinitely.
#
# BOTH PROFILES: unlike the ALB/SG backstop (profile=full only — the ALB
# controller + external-dns are profile-gated, A6 #178), Karpenter is installed
# by `var.enable_karpenter` (terraform/modules/regional-stack/variables.tf),
# which is independent of `cluster_profile`. An ephemeral cluster runs Karpenter
# nodes exactly like a full one, so it carries the identical orphan-EC2 risk.
# infra-ops.yml calls this script unconditionally, on both branches.
#
# SCOPING — why this cannot touch another cluster's or the MNG's instances:
#   - `kubernetes.io/cluster/<CLUSTER>` = `owned` is one of Karpenter's
#     "restricted domain" tags (karpenter.sh: EC2NodeClass.spec.tags may not
#     override kubernetes.io/cluster/*, karpenter.sh/*, karpenter.k8s.aws/*) —
#     Karpenter itself sets it, to the EXACT cluster name, on every instance it
#     launches. It is never another cluster's value.
#   - `karpenter.sh/nodepool` (tag-KEY filter, any value) exists ONLY on
#     instances Karpenter launched. The static managed node group (eks.tf) is a
#     plain ASG-backed EKS-managed nodegroup; its instances never carry this
#     tag, so they never match even though they share the same
#     kubernetes.io/cluster/<CLUSTER> tag.
#   AWS CLI ANDs separate `--filters` entries together (values within one entry
#   OR together) — so "cluster tag = THIS cluster" AND "nodepool tag exists" AND
#   "not already terminated" is the precise intersection: Karpenter-launched
#   instances owned by THIS cluster, nothing else can match.
#
#   Usage: scripts/dr/karpenter-quiesce.sh <region> [cluster-name]
#
#   <region>       : AWS region (required)
#   [cluster-name] : EKS cluster name (optional; defaults to aegis-platform-<region>,
#                    same convention as pre-destroy.sh — pass it explicitly when
#                    the caller already has the terraform output)
#
# Idempotent / always exits 0: every external call has a bounded recovery path,
# so a wedged quiesce never fails the teardown job outright — the CALLER's
# post-destroy orphan verification (infra-ops.yml destroy-region) is the loud,
# job-failing backstop of last resort if this script's own fail-safe still
# leaves an orphan behind.

set -uo pipefail  # deliberately NOT -e: every step below owns its own recovery

REGION="${1:?usage: karpenter-quiesce.sh <region> [cluster-name]}"
CLUSTER="${2:-aegis-platform-${REGION}}"
CLUSTER_TAG="kubernetes.io/cluster/${CLUSTER}"

if ! aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  echo "karpenter-quiesce: cluster $CLUSTER not found — nothing to quiesce, skipping."
  exit 0
fi

count_orphans() {
  aws ec2 describe-instances --region "$REGION" \
    --filters "Name=tag:${CLUSTER_TAG},Values=owned" \
              "Name=tag-key,Values=karpenter.sh/nodepool" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null
}

# ── Step 1: graceful quiesce (best-effort, bounded) ─────────────────────────
# While the controller MAY still be reachable, ask Karpenter to drain + reap its
# own fleet the clean way: deleting a NodeClaim triggers Karpenter's own
# termination path (cordon -> evict, respecting PodDisruptionBudgets -> EC2
# TerminateInstances). When it completes this is strictly better than the
# AWS-API fail-safe below — pods get a real PDB-respecting drain instead of a
# hard instance kill. `kubectl delete nodeclaims --all` is scoped to whatever
# cluster the kubeconfig just pointed at (this CLUSTER only) — no cross-cluster
# reach is structurally possible here.
if aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  if kubectl get nodeclaims >/dev/null 2>&1; then
    echo "karpenter-quiesce: deleting all NodeClaims to trigger a graceful drain+terminate..."
    kubectl delete nodeclaims --all --ignore-not-found --timeout=60s >/dev/null 2>&1 \
      || echo "karpenter-quiesce: NodeClaim delete did not confirm within 60s (controller may already be gone, or a stuck finalizer is blocking eviction) — falling through to the AWS-API fail-safe."

    echo "karpenter-quiesce: waiting up to 180s for tag-scoped instances to clear..."
    deadline=$(( $(date +%s) + 180 ))
    while true; do
      remaining="$(count_orphans)"
      if [ -z "$remaining" ]; then
        echo "karpenter-quiesce: graceful quiesce cleared all Karpenter-tagged instances for ${CLUSTER}."
        break
      fi
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "karpenter-quiesce: quiesce TIMED OUT after 180s with instance(s) still present: ${remaining}"
        break
      fi
      sleep 10
    done
  else
    echo "karpenter-quiesce: NodeClaim CRD not reachable (controller not installed, or already torn down) — skipping the graceful step."
  fi
else
  echo "karpenter-quiesce: could not reach the cluster API (kubeconfig update failed) — skipping the graceful step, going straight to the AWS-API fail-safe."
fi

# ── Step 2: AWS-API fail-safe — terminate by tag whatever the graceful step
# missed (a wedged quiesce, a dead controller, an unreachable API server, or no
# kubectl at all). This is the actual #200 deliverable; Step 1 above is the
# "try nicely first" half of the same fail-safe philosophy the ALB/SG backstop
# already uses (pre-destroy.sh drains gracefully, then the AWS-API ALB backstop
# in infra-ops.yml covers a wedged controller the same way).
orphans="$(count_orphans)"
if [ -z "$orphans" ]; then
  echo "karpenter-quiesce: no orphan Karpenter-tagged EC2 for ${CLUSTER} in ${REGION} — fail-safe has nothing to do."
  exit 0
fi

echo "::warning::karpenter-quiesce: quiesce did not clear all nodes — terminating orphan Karpenter-tagged EC2 in ${REGION} for ${CLUSTER}: ${orphans}"
# shellcheck disable=SC2086  # $orphans is a deliberately unquoted space-separated instance-id list — `aws ec2 terminate-instances --instance-ids` takes N positional args, not one string
aws ec2 terminate-instances --region "$REGION" --instance-ids $orphans >/dev/null 2>&1 \
  || echo "::warning::karpenter-quiesce: terminate-instances call failed (instance(s) may already be terminating, or already gone) — continuing to verify."

echo "karpenter-quiesce: waiting up to 120s for termination to take effect..."
deadline=$(( $(date +%s) + 120 ))
while true; do
  remaining="$(count_orphans)"
  if [ -z "$remaining" ]; then
    echo "karpenter-quiesce: fail-safe confirmed — zero orphan Karpenter-tagged EC2 remain for ${CLUSTER}."
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "::warning::karpenter-quiesce: instance(s) still not terminated after 120s: ${remaining}. terraform destroy may hit DependencyViolation on the VPC/subnet (a terminating instance holds its ENI until fully gone); the post-destroy orphan verification in infra-ops.yml destroy-region will fail loud if any instance is still present after destroy returns."
    break
  fi
  sleep 10
done

exit 0
