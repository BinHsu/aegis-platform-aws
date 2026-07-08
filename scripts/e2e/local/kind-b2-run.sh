#!/usr/bin/env bash
# scripts/e2e/local/kind-b2-run.sh
#
# LOCAL wrapper for the B2 sample-workload onboarding E2E (epic #167 / ADR-26,
# issue #171) on a throwaway kind cluster — WITHOUT pushing the branch. It is the
# B2 counterpart to scripts/e2e/local/kind-gitops-run.sh: it stands up the GitOps
# golden path, then onboards a sample workload through the workload ApplicationSet
# (List generator + templatePatch injections) with its image served from a local
# registry:2 — exactly what CI's e2e-golden-path.yml runs against the pushed PR.
#
# It serves THIS worktree's committed HEAD over the kind docker network via an
# in-cluster git daemon (same reasons as kind-gitops-run.sh: kind DNS + Calico
# pod-CIDR routing), so ArgoCD reads the fixture (fixtures/sample-deploy) and the
# app-of-apps straight from your local commits.
#
# Requires: docker, kind, kubectl, helm, git, yq, jq, curl. crane is fetched to a
# temp dir if not on PATH (non-host-mutating).
# Usage:   ./scripts/e2e/local/kind-b2-run.sh          # HEAD of current branch
#          KEEP=1 ./scripts/e2e/local/kind-b2-run.sh   # leave cluster + registry up
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-aegis-b2-e2e}"
GIT_PORT=9418
GIT_NS="git-server"
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
SERVE_DIR="$(mktemp -d)"
KUBECONFIG="$(mktemp)"
export KUBECONFIG

# The digest-pinned image the fixture (fixtures/sample-deploy) references. crane
# copy preserves this digest into localhost:5000/aegis-sample.
SAMPLE_SRC_IMAGE="busybox:1.37@sha256:9532d8c39891ca2ecde4d30d7710e01fb739c87a8b9299685c63704296b16028"
SAMPLE_DST_REPO="aegis-sample"

# shellcheck source=../b2/local-registry.sh
source "$REPO_ROOT/scripts/e2e/b2/local-registry.sh"

cleanup() {
  echo "==> cleanup"
  rm -rf "$SERVE_DIR"
  if [ "${KEEP:-0}" != "1" ]; then
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    registry_down
  else
    echo "    KEEP=1 — cluster '$CLUSTER_NAME' + registry left up (KUBECONFIG=$KUBECONFIG)"
  fi
}
trap cleanup EXIT

echo "==> [local] Building a bare git mirror of worktree HEAD ($BRANCH)"
git clone --quiet --bare "$REPO_ROOT" "$SERVE_DIR/repo.git"
git -C "$SERVE_DIR/repo.git" update-server-info

echo "==> [local] Creating kind cluster '$CLUSTER_NAME' (Calico + localhost:5000 registry mirror)"
kind create cluster --name "$CLUSTER_NAME" \
  --config "$REPO_ROOT/scripts/e2e/kind/kind-calico.yaml" --wait 0s

echo "==> [local] Starting + seeding the local registry:2"
registry_up "$CLUSTER_NAME"
registry_seed "$SAMPLE_SRC_IMAGE" "$SAMPLE_DST_REPO"

echo "==> [local] Installing Calico (NetworkPolicy-enforcing CNI)"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl -n kube-system rollout status deployment/coredns --timeout=180s

# ── Serve the mirror from an in-cluster git daemon (identical to kind-gitops-run.sh) ──
echo "==> [local] Serving the mirror in-cluster via git daemon (svc b2-git.$GIT_NS:$GIT_PORT)"
kubectl create namespace "$GIT_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$GIT_NS" -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: b2-git
spec:
  replicas: 1
  selector: { matchLabels: { app: b2-git } }
  template:
    metadata: { labels: { app: b2-git } }
    spec:
      containers:
        - name: git
          image: alpine/git
          imagePullPolicy: IfNotPresent
          command: ["sh", "-c", "apk add --no-cache git-daemon >/dev/null 2>&1; until [ -f /srv/.ready ]; do sleep 1; done; exec git daemon --verbose --reuseaddr --listen=0.0.0.0 --port=$GIT_PORT --base-path=/srv --export-all --enable=upload-pack"]
          ports: [{ containerPort: $GIT_PORT }]
          volumeMounts: [{ name: srv, mountPath: /srv }]
      volumes: [{ name: srv, emptyDir: {} }]
---
apiVersion: v1
kind: Service
metadata:
  name: b2-git
spec:
  selector: { app: b2-git }
  ports: [{ port: $GIT_PORT, targetPort: $GIT_PORT }]
YAML
kubectl -n "$GIT_NS" rollout status deploy/b2-git --timeout=120s
GIT_POD="$(kubectl -n "$GIT_NS" get pod -l app=b2-git -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$GIT_NS" cp "$SERVE_DIR/repo.git" "$GIT_POD:/srv/repo.git"
kubectl -n "$GIT_NS" exec "$GIT_POD" -- touch /srv/.ready
LOCAL_REPO_URL="git://b2-git.$GIT_NS.svc.cluster.local:$GIT_PORT/repo.git"
echo "    git mirror in-cluster: $LOCAL_REPO_URL (branch $BRANCH)"

echo "==> [local] Bringing up the GitOps golden path (ArgoCD + Kyverno + policies)"
REPO_URL="$LOCAL_REPO_URL" TARGET_REVISION="$BRANCH" \
  "$REPO_ROOT/scripts/e2e/gitops-golden-path.sh"

echo "==> [local] Onboarding the sample workload via the ApplicationSet fan-out"
REPO_URL="$LOCAL_REPO_URL" TARGET_REVISION="$BRANCH" \
  "$REPO_ROOT/scripts/e2e/b2/assert-workload-onboarding.sh"

echo ""
echo "==> B2 KIND E2E PASSED — sample workload onboarded via ApplicationSet fan-out,"
echo "    image served from the local registry:2, injections + negatives green."
