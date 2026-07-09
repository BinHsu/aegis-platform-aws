#!/usr/bin/env bash
# scripts/verify/local/kind-verifier-smoke.sh
#
# LOCAL kind smoke for the Tier-2 in-cluster verifier (#145). Proves the
# UNATTENDED PLUMBING that replaces the laptop port-forward path end-to-end on a
# throwaway kind cluster, with NO port-forward and NO `kill`/`pkill`:
#
#   1. build the verifier image from Dockerfile.verifier (the same image the
#      verifier-image workflow publishes),
#   2. `kind load` it (imagePullPolicy: IfNotPresent — no registry needed),
#   3. seed the proto + PCM ConfigMaps into aegis-core (the #145 point-2 bring-up
#      step) and the aegis-core-engine ServiceAccount the Job runs as,
#   4. apply the REAL verifier-job.yaml (envsubst, as run-incluster-verify.sh
#      does), wait for the Job pod to reach a terminal state, fetch its logs.
#
# WHAT THIS PROVES: the image builds, is pullable in-cluster, the ConfigMaps
# mount read-only, /tmp is writable, the non-root securityContext admits, and the
# entrypoint (in-cluster-verify.py) runs to its PASS/FAIL summary INSIDE the
# cluster over service DNS — the whole unattended path minus the app.
#
# WHAT THIS DOES NOT PROVE: the F2-F8 faces themselves. They need a live
# aegis-core (engine/gateway) + Cognito, which do not exist on bare kind — so the
# faces FAIL here BY DESIGN and the Job pod ends Failed. That full run is the
# real-cluster lane (run-incluster-verify.sh against staging). This smoke gates
# the plumbing only, so it asserts the summary table was produced, not that the
# faces passed.
#
# Requires: docker, kind, kubectl, envsubst.
# Usage:   ./scripts/verify/local/kind-verifier-smoke.sh
#          KEEP=1 ./scripts/verify/local/kind-verifier-smoke.sh   # leave cluster up
set -euo pipefail

VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-aegis-verify-smoke}"
NS="${NS:-aegis-core}"
IMAGE="${IMAGE:-aegis-verify:smoke}"
KUBECONFIG="$(mktemp)"
export KUBECONFIG
WORK="$(mktemp -d)"

cleanup() {
  echo "==> cleanup"
  rm -rf "$WORK"
  if [ "${KEEP:-0}" != "1" ]; then
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  else
    echo "    KEEP=1 — cluster '$CLUSTER_NAME' left up (KUBECONFIG=$KUBECONFIG)"
  fi
}
trap cleanup EXIT

echo "==> [1/5] build verifier image ($IMAGE) from Dockerfile.verifier"
docker build -f "$VERIFY_DIR/Dockerfile.verifier" -t "$IMAGE" "$VERIFY_DIR"

echo "==> [2/5] create kind cluster '$CLUSTER_NAME' and load the image"
kind create cluster --name "$CLUSTER_NAME" --wait 60s
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

echo "==> [3/5] seed namespace, ServiceAccount, and proto + PCM ConfigMaps"
kubectl create namespace "$NS" >/dev/null 2>&1 || true
# The Job runs as aegis-core-engine (reused for F7 s3 read on a real cluster).
kubectl -n "$NS" create serviceaccount aegis-core-engine >/dev/null 2>&1 || true
# Minimal fixtures — content is irrelevant to the plumbing (the faces need the
# real app, absent here). A tiny proto + a 1 KiB PCM are enough to mount.
printf 'syntax = "proto3";\npackage aegis.v1;\n' > "$WORK/aegis.proto"
head -c 1024 /dev/zero > "$WORK/fixture.pcm"
kubectl -n "$NS" create configmap aegis-proto \
  --from-file="aegis.proto=$WORK/aegis.proto" >/dev/null
kubectl -n "$NS" create configmap aegis-pcm-fixture \
  --from-file="fixture.pcm=$WORK/fixture.pcm" >/dev/null

echo "==> [4/5] render verifier-job.yaml (envsubst) and apply"
export VERIFY_IMAGE="$IMAGE" \
       PROTO_CONFIGMAP="aegis-proto" PCM_CONFIGMAP="aegis-pcm-fixture" \
       COGNITO_DOMAIN="https://smoke.invalid" CLIENT_ID="smoke" POOL="smoke" \
       COGNITO_REGION="eu-central-1" MODEL_BUCKET="" AWS_REGION="" \
       JOB_SUFFIX="smoke"
JOB_NAME="aegis-verify-smoke"
envsubst < "$VERIFY_DIR/k8s/verifier-job.yaml" | kubectl apply -f - >/dev/null

echo "==> [5/5] wait for the Job pod to reach a terminal state, then read logs"
# The Job fails by design (no app to verify), so wait on pod PHASE, not
# condition=complete. backoffLimit:0 → exactly one pod, terminal in Succeeded or
# Failed. Guard against ImagePullBackOff (the plumbing failure we DO care about).
deadline=$(( $(date +%s) + 180 ))
phase=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  phase="$(kubectl -n "$NS" get pods -l job-name="$JOB_NAME" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
  waiting_reason="$(kubectl -n "$NS" get pods -l job-name="$JOB_NAME" \
            -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  case "$waiting_reason" in
    ErrImagePull|ImagePullBackOff|InvalidImageName|CreateContainerError)
      echo "FAIL: container could not start ($waiting_reason) — image/plumbing broken" >&2
      kubectl -n "$NS" describe pods -l job-name="$JOB_NAME" >&2 || true
      exit 1 ;;
  esac
  case "$phase" in
    Succeeded|Failed) break ;;
  esac
  sleep 3
done

echo "==> pod terminal phase: ${phase:-<none>}"
LOGS="$(kubectl -n "$NS" logs "job/$JOB_NAME" 2>/dev/null || true)"
echo "----- verifier logs -----"
echo "$LOGS"
echo "-------------------------"

# Plumbing assertion: the entrypoint ran to its summary table inside the cluster.
# (The faces are FAIL here — expected without the app; we assert the RUN, not the
# result.)
if echo "$LOGS" | grep -q "^FACE" && echo "$LOGS" | grep -q "^OVERALL:"; then
  echo "PASS: verifier entrypoint ran end-to-end in-cluster (plumbing OK — no port-forward, no kill)."
  exit 0
fi

echo "FAIL: verifier entrypoint did not produce its summary table — plumbing broken." >&2
exit 1
