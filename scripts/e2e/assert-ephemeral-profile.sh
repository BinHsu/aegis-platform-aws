#!/usr/bin/env bash
# scripts/e2e/assert-ephemeral-profile.sh
#
# A6 (epic #167 / issue #178, ADR-25) — PROFILE-GATING assertion.
#
# PRECONDITION: the GitOps golden path is already up on the cluster given by
# $KUBECONFIG (run scripts/e2e/gitops-golden-path.sh first) — ArgoCD WITH the
# applicationset controller.
#
# WHAT IT PROVES: the two profile-scoped add-ons — the ALB controller and
# external-dns — are delivered ONLY to clusters whose facts-bridge profile is
# "full", and NOT to ephemeral clusters. That gating is the whole mechanism A6
# rides: an ephemeral cluster never installs the two add-ons that create AWS
# objects outside Terraform state (ALBs, controller SGs, Route53 records), so its
# teardown collapses to a plain `terraform destroy` (see infra-ops.yml).
#
# HOW (hermetic, $0, no AWS): we register a SYNTHETIC ArgoCD `cluster` Secret
# that mimics the Terraform facts bridge (gitops-bootstrap.tf) — same
# secret-type=cluster label + the same annotations the two ApplicationSets read —
# and flip its aegis.binhsu.org/profile LABEL between "full" and "ephemeral",
# asserting the generated Application appears / disappears in lock-step.
#
#   * The synthetic cluster's data.server points at a BOGUS unreachable URL on
#     purpose: ArgoCD can GENERATE the child Application (selector + template are
#     evaluated against the Secret's labels/annotations, no connectivity needed)
#     but can never SYNC the real Helm chart onto this kind cluster. So this test
#     proves the SELECTOR, with zero risk of the ALB controller's webhooks landing
#     on the shared golden-path cluster.
#   * We assert the FULL case first (apps must APPEAR) then the EPHEMERAL case
#     (apps must DISAPPEAR): both are controller-driven transitions, more reliable
#     than asserting a pre-reconcile absence.
#
# Usage: KUBECONFIG=... ./scripts/e2e/assert-ephemeral-profile.sh
#   Requires: kubectl.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDONS="$REPO_ROOT/gitops/platform-addons/addons"
ALB_APPSET="$ADDONS/alb-controller/application.yaml"
EDNS_APPSET="$ADDONS/external-dns/application.yaml"
ARGOCD_NS="argocd"

# Synthetic facts-bridge cluster Secret (mimics gitops-bootstrap.tf). The server
# is deliberately unreachable so generated apps can never sync a real chart here.
FACTS_SECRET="aegis-a6-profile-probe"
PROBE_CLUSTER_NAME="aegis-a6-profile-probe"
# The ApplicationSet template names the app "<addon>-<nameNormalized>".
ALB_APP="aws-load-balancer-controller-${PROBE_CLUSTER_NAME}"
EDNS_APP="external-dns-${PROBE_CLUSTER_NAME}"

dump_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo ""
    echo "########################################################################"
    echo "## FAILURE (exit $rc) — A6 profile-gating assertion"
    echo "########################################################################"
    echo "--- applicationsets -n argocd ---"; kubectl get applicationset -n "$ARGOCD_NS" -o wide 2>/dev/null || true
    echo "--- applications -n argocd ---";     kubectl get applications -n "$ARGOCD_NS" 2>/dev/null || true
    echo "--- facts secret labels ---";        kubectl get secret "$FACTS_SECRET" -n "$ARGOCD_NS" --show-labels 2>/dev/null || true
    echo "--- alb appset status ---";          kubectl get applicationset aws-load-balancer-controller -n "$ARGOCD_NS" -o jsonpath='{.status.conditions}' 2>/dev/null || true; echo
    echo "########################################################################"
  fi
  # Best-effort teardown so a failed run leaves no synthetic cluster / dangling apps.
  cleanup || true
  exit "$rc"
}

cleanup() {
  kubectl delete -f "$ALB_APPSET"  --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
  kubectl delete -f "$EDNS_APPSET" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
  kubectl delete secret "$FACTS_SECRET" -n "$ARGOCD_NS" --ignore-not-found >/dev/null 2>&1 || true
}
trap dump_on_failure EXIT

# poll_until_present <app-name> <timeout-s>
poll_until_present() {
  local app="$1" timeout="${2:-60}" t=0
  while [ "$t" -lt "$timeout" ]; do
    kubectl get application "$app" -n "$ARGOCD_NS" >/dev/null 2>&1 && return 0
    sleep 3; t=$((t + 3))
  done
  return 1
}

# poll_until_absent <app-name> <timeout-s>
poll_until_absent() {
  local app="$1" timeout="${2:-60}" t=0
  while [ "$t" -lt "$timeout" ]; do
    kubectl get application "$app" -n "$ARGOCD_NS" >/dev/null 2>&1 || return 0
    sleep 3; t=$((t + 3))
  done
  return 1
}

# ── 0. preflight ─────────────────────────────────────────────────────────────
echo "==> [0] Preflight: ArgoCD applicationset controller present"
kubectl rollout status deploy/argocd-applicationset-controller -n "$ARGOCD_NS" --timeout=120s

# ── 1. apply the two profile-gated ApplicationSets (idempotent) ──────────────
echo "==> [1] Applying the ALB controller + external-dns ApplicationSets"
kubectl apply -f "$ALB_APPSET"
kubectl apply -f "$EDNS_APPSET"

# ── 2. seed the synthetic facts bridge, profile=FULL ─────────────────────────
# Carries every annotation the two appsets read (missingkey=error) PLUS the
# annotations OTHER clusters-generator appsets on this cluster read (workloads,
# account-id) so seeding this Secret does not error them. observability is left
# unset so the Alloy appset stays inert. data.server is unreachable on purpose.
echo "==> [2] Seeding synthetic facts-bridge cluster Secret (profile=full)"
apply_facts_secret() {
  local profile="$1"
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: $FACTS_SECRET
  namespace: $ARGOCD_NS
  labels:
    argocd.argoproj.io/secret-type: cluster
    aegis.binhsu.org/profile: "$profile"
  annotations:
    aegis.binhsu.org/cluster-name: "$PROBE_CLUSTER_NAME"
    aegis.binhsu.org/region: "eu-central-1"
    aegis.binhsu.org/account-id: "000000000000"
    aegis.binhsu.org/vpc-id: "vpc-0a6profileprobe000"
    aegis.binhsu.org/alb-role-arn: "arn:aws:iam::000000000000:role/aegis-a6-alb-probe"
    aegis.binhsu.org/external-dns-role-arn: "arn:aws:iam::000000000000:role/aegis-a6-edns-probe"
    aegis.binhsu.org/zone-name: "a6-probe.example.com"
    aegis.binhsu.org/workloads: "[]"
type: Opaque
stringData:
  name: "$PROBE_CLUSTER_NAME"
  server: "https://aegis-a6-profile-probe.invalid:6443"
  config: '{"tlsClientConfig":{"insecure":false}}'
YAML
}
apply_facts_secret full

echo "==> [3-assert] FULL profile → both add-on Applications must be GENERATED"
poll_until_present "$ALB_APP" 90 || { echo "    FAIL: '$ALB_APP' was not generated under profile=full."; exit 1; }
poll_until_present "$EDNS_APP" 90 || { echo "    FAIL: '$EDNS_APP' was not generated under profile=full."; exit 1; }
echo "    OK: profile=full generated both '$ALB_APP' and '$EDNS_APP'."

# ── 4. flip the profile LABEL to ephemeral ───────────────────────────────────
echo "==> [4] Flipping the facts-bridge profile LABEL to ephemeral"
apply_facts_secret ephemeral

echo "==> [5-assert] EPHEMERAL profile → both add-on Applications must DISAPPEAR"
poll_until_absent "$ALB_APP" 90 || { echo "    FAIL: '$ALB_APP' still present under profile=ephemeral (selector did not exclude it)."; exit 1; }
poll_until_absent "$EDNS_APP" 90 || { echo "    FAIL: '$EDNS_APP' still present under profile=ephemeral (selector did not exclude it)."; exit 1; }
echo "    OK: profile=ephemeral removed both '$ALB_APP' and '$EDNS_APP'."

# ── 6. teardown ──────────────────────────────────────────────────────────────
echo "==> [6] Teardown: removing synthetic cluster Secret + the two ApplicationSets"
cleanup
trap - EXIT

echo ""
echo "==> A6 PROFILE-GATING PROVED (zero AWS spend):"
echo "    profile=full      → ALB controller + external-dns Applications generated"
echo "    profile=ephemeral → both excluded (no ALB/SG/Route53-creating add-on)"
echo "    => an ephemeral cluster's teardown collapses to a plain terraform destroy."
