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
# HOW (hermetic, deterministic, $0, no AWS): we register TWO synthetic ArgoCD
# `cluster` Secrets that mimic the Terraform facts bridge (gitops-bootstrap.tf) —
# one labelled profile=full, one profile=ephemeral — SIMULTANEOUSLY, then assert
# the ALB / external-dns Application is generated for the FULL cluster and NOT for
# the EPHEMERAL one.
#
#   * Both secrets carry the same annotations the two ApplicationSets read
#     (missingkey=error) plus the annotations OTHER clusters-generator appsets on
#     this cluster read (workloads, account-id), so seeding them errors nothing;
#     observability is left unset so the Alloy appset stays inert.
#   * data.server on both points at a BOGUS unreachable URL on purpose: ArgoCD can
#     GENERATE the child Application (selector + template are evaluated against the
#     Secret's labels/annotations, no connectivity needed) but can never SYNC the
#     real Helm chart onto this kind cluster. So this proves the SELECTOR with zero
#     risk of the ALB controller's webhooks landing on the shared golden-path cluster.
#   * The test is a pure GENERATION check, not a transition/removal one: because
#     the FULL app APPEARING is itself proof the clusters generator reconciled
#     against BOTH secrets, the EPHEMERAL app's ABSENCE in that same generated set
#     is definitive (not merely "not reconciled yet"). No dependency on ArgoCD's
#     slow delete-on-fall-out.
#
# Usage: KUBECONFIG=... ./scripts/e2e/assert-ephemeral-profile.sh
#   Requires: kubectl.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADDONS="$REPO_ROOT/gitops/platform-addons/addons"
ALB_APPSET="$ADDONS/alb-controller/application.yaml"
EDNS_APPSET="$ADDONS/external-dns/application.yaml"
ARGOCD_NS="argocd"

# Two synthetic facts-bridge cluster Secrets (mimic gitops-bootstrap.tf). Servers
# are deliberately unreachable so generated apps can never sync a real chart here.
FULL_SECRET="aegis-a6-full"
EPH_SECRET="aegis-a6-eph"
FULL_CLUSTER="a6full"
EPH_CLUSTER="a6eph"
# The ApplicationSet template names the app "<addon>-<nameNormalized>".
ALB_FULL_APP="aws-load-balancer-controller-${FULL_CLUSTER}"
ALB_EPH_APP="aws-load-balancer-controller-${EPH_CLUSTER}"
EDNS_FULL_APP="external-dns-${FULL_CLUSTER}"
EDNS_EPH_APP="external-dns-${EPH_CLUSTER}"

dump_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo ""
    echo "########################################################################"
    echo "## FAILURE (exit $rc) — A6 profile-gating assertion"
    echo "########################################################################"
    echo "--- applicationsets -n argocd ---"; kubectl get applicationset -n "$ARGOCD_NS" -o wide 2>/dev/null || true
    echo "--- applications -n argocd ---";     kubectl get applications -n "$ARGOCD_NS" 2>/dev/null || true
    echo "--- probe cluster secrets ---";      kubectl get secret "$FULL_SECRET" "$EPH_SECRET" -n "$ARGOCD_NS" --show-labels 2>/dev/null || true
    echo "########################################################################"
  fi
  # Best-effort teardown so a failed run leaves no synthetic cluster / dangling apps.
  cleanup || true
  exit "$rc"
}

cleanup() {
  kubectl delete secret "$FULL_SECRET" "$EPH_SECRET" -n "$ARGOCD_NS" --ignore-not-found >/dev/null 2>&1 || true
  kubectl delete -f "$ALB_APPSET"  --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
  kubectl delete -f "$EDNS_APPSET" --ignore-not-found --timeout=60s >/dev/null 2>&1 || true
}
trap dump_on_failure EXIT

# apply_facts_secret <secret-name> <cluster-name> <profile>
apply_facts_secret() {
  local secret="$1" cluster="$2" profile="$3"
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: $secret
  namespace: $ARGOCD_NS
  labels:
    argocd.argoproj.io/secret-type: cluster
    aegis.binhsu.org/profile: "$profile"
  annotations:
    aegis.binhsu.org/cluster-name: "$cluster"
    aegis.binhsu.org/region: "eu-central-1"
    aegis.binhsu.org/account-id: "000000000000"
    aegis.binhsu.org/vpc-id: "vpc-0a6profileprobe000"
    aegis.binhsu.org/alb-role-arn: "arn:aws:iam::000000000000:role/aegis-a6-alb-probe"
    aegis.binhsu.org/external-dns-role-arn: "arn:aws:iam::000000000000:role/aegis-a6-edns-probe"
    aegis.binhsu.org/zone-name: "a6-probe.example.com"
    aegis.binhsu.org/workloads: "[]"
type: Opaque
stringData:
  name: "$cluster"
  server: "https://${cluster}.aegis-a6-probe.invalid:6443"
  config: '{"tlsClientConfig":{"insecure":false}}'
YAML
}

# poll_until_present <app-name> <timeout-s>
poll_until_present() {
  local app="$1" timeout="${2:-120}" t=0
  while [ "$t" -lt "$timeout" ]; do
    kubectl get application "$app" -n "$ARGOCD_NS" >/dev/null 2>&1 && return 0
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

# ── 2. register BOTH synthetic clusters at once (full + ephemeral) ───────────
echo "==> [2] Registering synthetic clusters: '$FULL_CLUSTER' (profile=full) + '$EPH_CLUSTER' (profile=ephemeral)"
apply_facts_secret "$FULL_SECRET" "$FULL_CLUSTER" full
apply_facts_secret "$EPH_SECRET"  "$EPH_CLUSTER"  ephemeral

# ── 3. FULL cluster must generate BOTH add-on Applications ────────────────────
# (Their presence is also the signal that the clusters generator has reconciled
# against both Secrets — which makes the ephemeral-absence check below definitive.)
echo "==> [3-assert] profile=full cluster → ALB controller + external-dns generated"
poll_until_present "$ALB_FULL_APP"  120 || { echo "    FAIL: '$ALB_FULL_APP' not generated for the full cluster."; exit 1; }
poll_until_present "$EDNS_FULL_APP" 120 || { echo "    FAIL: '$EDNS_FULL_APP' not generated for the full cluster."; exit 1; }
echo "    OK: full cluster generated '$ALB_FULL_APP' + '$EDNS_FULL_APP' (generator has reconciled both clusters)."

# ── 4. EPHEMERAL cluster must generate NEITHER ───────────────────────────────
# The generator has demonstrably reconciled (step 3), so if the ephemeral apps do
# not exist NOW, the selector excluded them — not a race. Re-check after a short
# settle to be safe.
echo "==> [4-assert] profile=ephemeral cluster → NEITHER add-on generated"
sleep 10
for app in "$ALB_EPH_APP" "$EDNS_EPH_APP"; do
  if kubectl get application "$app" -n "$ARGOCD_NS" >/dev/null 2>&1; then
    echo "    FAIL: '$app' was generated for the ephemeral cluster (selector did not exclude profile=ephemeral)."; exit 1
  fi
done
echo "    OK: ephemeral cluster generated NEITHER '$ALB_EPH_APP' nor '$EDNS_EPH_APP'."

# ── 5. teardown ──────────────────────────────────────────────────────────────
echo "==> [5] Teardown: removing synthetic cluster Secrets + the two ApplicationSets"
cleanup
trap - EXIT

echo ""
echo "==> A6 PROFILE-GATING PROVED (zero AWS spend):"
echo "    profile=full      → ALB controller + external-dns Applications generated"
echo "    profile=ephemeral → both excluded (no ALB/SG/Route53-creating add-on)"
echo "    => an ephemeral cluster's teardown collapses to a plain terraform destroy."
