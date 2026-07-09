#!/usr/bin/env bash
# scripts/e2e/local/kind-crossplane-gitops-run.sh
#
# LOCAL wrapper that runs the A3 GitOps-delivery Crossplane E2E
# (crossplane-gitops-golden-path.sh) on a throwaway kind cluster — WITHOUT pushing
# the branch anywhere. It serves THIS worktree's committed HEAD over the kind
# docker network via an in-cluster git daemon, so ArgoCD reads the crossplane
# child apps + the in-repo aegis-xrds-v2 chart straight from your local commits.
#
# Local counterpart to the crossplane-kind-integration CI workflow's gitops job.
# kind-in-CI against the pushed branch stays the real gate. Crossplane needs no
# NetworkPolicy CNI, so this uses plain kind (kindnet) — no Calico, unlike
# kind-gitops-run.sh (A2).
#
# Requires: docker, kind, kubectl, helm, git, yq.
# Usage:   ./scripts/e2e/local/kind-crossplane-gitops-run.sh        # HEAD of current branch
#          KEEP=1 ./scripts/e2e/local/kind-crossplane-gitops-run.sh # leave cluster up
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-aegis-a3-xp-e2e}"
GIT_PORT=9418
GIT_NS="git-server"
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
SERVE_DIR="$(mktemp -d)"
KUBECONFIG="$(mktemp)"
export KUBECONFIG

cleanup() {
  echo "==> cleanup"
  rm -rf "$SERVE_DIR"
  if [ "${KEEP:-0}" != "1" ]; then
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  else
    echo "    KEEP=1 — cluster '$CLUSTER_NAME' left up (KUBECONFIG=$KUBECONFIG)"
  fi
}
trap cleanup EXIT

echo "==> [local] Building a bare mirror of worktree HEAD ($BRANCH)"
git clone --quiet --bare "$REPO_ROOT" "$SERVE_DIR/repo.git"
git -C "$SERVE_DIR/repo.git" update-server-info

echo "==> [local] Creating kind cluster '$CLUSTER_NAME' (default CNI — no NetworkPolicy needed)"
kind create cluster --name "$CLUSTER_NAME" --wait 120s

# ── Serve the mirror from an IN-CLUSTER git daemon (git:// smart protocol) ────
# Same mechanism + rationale as scripts/e2e/local/kind-gitops-run.sh: an
# in-cluster Service gives ArgoCD's repo-server clean cluster-DNS routing, and
# git daemon speaks the SMART protocol ArgoCD syncs reliably (dumb-HTTP errors
# "unexpected EOF" in repo-server manifest-gen).
echo "==> [local] Serving the mirror in-cluster via git daemon (svc a3-git.$GIT_NS:$GIT_PORT)"
kubectl create namespace "$GIT_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$GIT_NS" -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: a3-git
spec:
  replicas: 1
  selector: { matchLabels: { app: a3-git } }
  template:
    metadata: { labels: { app: a3-git } }
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
  name: a3-git
spec:
  selector: { app: a3-git }
  ports: [{ port: $GIT_PORT, targetPort: $GIT_PORT }]
YAML
kubectl -n "$GIT_NS" rollout status deploy/a3-git --timeout=120s
GIT_POD="$(kubectl -n "$GIT_NS" get pod -l app=a3-git -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$GIT_NS" cp "$SERVE_DIR/repo.git" "$GIT_POD:/srv/repo.git"
kubectl -n "$GIT_NS" exec "$GIT_POD" -- touch /srv/.ready
LOCAL_REPO_URL="git://a3-git.$GIT_NS.svc.cluster.local:$GIT_PORT/repo.git"
echo "    git mirror in-cluster: $LOCAL_REPO_URL (branch $BRANCH)"

echo "==> [local] Running crossplane-gitops-golden-path.sh (stack delivered by ArgoCD from the local mirror)"
REPO_URL="$LOCAL_REPO_URL" TARGET_REVISION="$BRANCH" \
  "$REPO_ROOT/scripts/e2e/crossplane-gitops-golden-path.sh"

echo ""
echo "==> A3 GITOPS CROSSPLANE E2E PASSED — core + definitions + providerconfig delivered by ArgoCD."
