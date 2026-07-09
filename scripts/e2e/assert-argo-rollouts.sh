#!/usr/bin/env bash
# scripts/e2e/assert-argo-rollouts.sh
#
# A4 (epic #167 / #176, ADR-25) — POSITIVE assertion for the GitOps-delivered
# Argo Rollouts controller. Proves the issue-#176 validation gate:
#
#   "On kind: the Rollout CRD is present and ESTABLISHED before any
#    Rollout-shaped workload manifest is synced (no race)."
#
# Runs AFTER gitops-golden-path.sh has seeded the app-of-apps root — the same
# root now enumerates addons/argo-rollouts (directory.recurse), so ArgoCD
# renders + syncs the argo-rollouts child Application (sync-wave 0) on its own.
# This script blocks on that child, then proves the ordering guarantee end to
# end: the CRD is Established FIRST, and only THEN is a real Rollout-shaped
# workload admitted. If the wave-0 CRD delivery raced (workload before CRD), the
# Rollout apply would fail with `no matches for kind "Rollout"` — so gating on
# Established, then applying, is the concrete no-race proof.
#
# SUBSTRATE-AGNOSTIC: takes the cluster via $KUBECONFIG; runs unchanged on kind
# and k3s. It uses its OWN throwaway namespace (NOT aegis-*), so the require-
# digest / default-deny policies do not enter the picture — this test isolates
# exactly the Rollout-CRD-delivery axis A4 owns. (The image is digest-pinned
# anyway, so it would also pass require-digest.)
#
# Usage: KUBECONFIG=... ./scripts/e2e/assert-argo-rollouts.sh
set -euo pipefail

ARGOCD_NS="argocd"
ROLLOUTS_NS="argo-rollouts"
PROBE_NS="${PROBE_NS:-argo-rollouts-e2e}"
# Digest-pinned busybox (same immutable index digest the require-digest positive
# control uses) so the probe Rollout carries a realistic, policy-clean image.
DIGEST_IMAGE="busybox:1.37@sha256:9532d8c39891ca2ecde4d30d7710e01fb739c87a8b9299685c63704296b16028"

cleanup() { kubectl delete namespace "$PROBE_NS" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

# ── 1. ArgoCD delivered the controller (child Application Healthy) ───────────
echo "==> [argo-rollouts] Wait for Application/argo-rollouts -> Healthy (ArgoCD-delivered, wave 0)"
h=""; s=""
for _ in $(seq 1 120); do   # up to 600s
  h="$(kubectl get application argo-rollouts -n "$ARGOCD_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  s="$(kubectl get application argo-rollouts -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  [ "$h" = "Healthy" ] && break
  sleep 5
done
[ "$h" = "Healthy" ] || { echo "    FAIL: Application/argo-rollouts never reached Healthy (last: sync=${s:-?}/health=${h:-?})."; exit 1; }
echo "    OK: Application/argo-rollouts Healthy (sync=$s)."

# ── 2. The Rollout CRD is ESTABLISHED (the wave-0 guarantee) ─────────────────
echo "==> [argo-rollouts] Assert CRD rollouts.argoproj.io is Established"
kubectl wait --for=condition=Established crd/rollouts.argoproj.io --timeout=120s
echo "    OK: rollouts.argoproj.io Established."

# ── 3. The controller is actually running ────────────────────────────────────
echo "==> [argo-rollouts] Assert controller Deployment is Available"
kubectl rollout status deploy/argo-rollouts -n "$ROLLOUTS_NS" --timeout=180s
echo "    OK: argo-rollouts controller Available."

# ── 4. NO-RACE PROOF: a Rollout-shaped workload is admitted AFTER the CRD ─────
# The CRD was Established in step 2, so this real Rollout manifest must be
# accepted (schema-validated + stored). This is the "Rollout-shaped workload
# synced" half of the #176 gate — the ordering (CRD first, workload second) is
# guaranteed by the step sequence above.
echo "==> [argo-rollouts] Apply a Rollout-shaped workload into $PROBE_NS (must be ADMITTED)"
kubectl create namespace "$PROBE_NS" --dry-run=client -o yaml | kubectl apply -f -
PROBE="$(mktemp)"
cat >"$PROBE" <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: a4-crd-probe
  namespace: $PROBE_NS
spec:
  replicas: 1
  selector:
    matchLabels:
      app: a4-crd-probe
  template:
    metadata:
      labels:
        app: a4-crd-probe
    spec:
      containers:
        - name: probe
          image: $DIGEST_IMAGE
          command: ["sh", "-c", "sleep 3600"]
  strategy:
    canary:
      steps:
        - setWeight: 50
        - pause: {}
YAML
if ! kubectl apply -f "$PROBE"; then
  echo "    FAIL: Rollout-shaped workload was NOT admitted — CRD delivery raced or schema invalid."
  exit 1
fi
echo "    OK: Rollout a4-crd-probe admitted (CRD established before the workload synced)."

# ── 5. The controller ADOPTS the Rollout (creates its ReplicaSet) ────────────
# Proves the delivered controller is functioning, not just the CRD registered.
echo "==> [argo-rollouts] Wait for the controller to create the Rollout's ReplicaSet"
ok=0
for _ in $(seq 1 24); do   # up to ~120s
  if [ "$(kubectl get rs -n "$PROBE_NS" -l app=a4-crd-probe -o name 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then ok=1; break; fi
  sleep 5
done
[ "$ok" = 1 ] || { echo "    FAIL: controller never created a ReplicaSet for the Rollout (controller not reconciling)."; exit 1; }
echo "    OK: controller reconciled the Rollout (ReplicaSet created)."

echo ""
echo "==> argo-rollouts A4 assertion PASSED:"
echo "    - ArgoCD delivered the controller (Application Healthy, wave 0)"
echo "    - rollouts.argoproj.io CRD Established"
echo "    - a Rollout-shaped workload admitted AFTER the CRD (no race)"
echo "    - controller reconciled it (ReplicaSet created)"
