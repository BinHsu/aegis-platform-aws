#!/usr/bin/env bash
# scripts/e2e/local/kind-gitops-run.sh
#
# LOCAL wrapper that runs the A2 GitOps-delivery E2E (gitops-golden-path.sh +
# the negative assertions) on a throwaway kind cluster — WITHOUT pushing the
# branch anywhere. It serves THIS worktree's committed HEAD over the kind docker
# network via a dumb-HTTP git mirror, so ArgoCD reads the app-of-apps straight
# from your local commits.
#
# This is the local counterpart to the (CI) e2e-golden-path workflow, for the
# GitOps-delivery path. kind-in-CI against the pushed branch stays the real gate.
#
# Requires: docker, kind, kubectl, helm, git, yq.
# Usage:   ./scripts/e2e/local/kind-gitops-run.sh        # HEAD of current branch
#          KEEP=1 ./scripts/e2e/local/kind-gitops-run.sh # leave cluster up
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
CLUSTER_NAME="${CLUSTER_NAME:-aegis-a2-e2e}"
KIND_NET="kind"                       # kind's default docker network
GIT_CTR="a2-git-server"
GIT_PORT=8080
BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)"
SERVE_DIR="$(mktemp -d)"
KUBECONFIG="$(mktemp)"
export KUBECONFIG

cleanup() {
  echo "==> cleanup"
  docker rm -f "$GIT_CTR" >/dev/null 2>&1 || true
  rm -rf "$SERVE_DIR"
  if [ "${KEEP:-0}" != "1" ]; then
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
  else
    echo "    KEEP=1 — cluster '$CLUSTER_NAME' left up (KUBECONFIG=$KUBECONFIG)"
  fi
}
trap cleanup EXIT

echo "==> [local] Serving worktree HEAD ($BRANCH) as a dumb-HTTP git mirror"
# A bare mirror of the committed branch. Dumb HTTP just needs static files +
# update-server-info; ArgoCD's git client clones it read-only over the kind net.
git clone --quiet --bare "$REPO_ROOT" "$SERVE_DIR/repo.git"
git -C "$SERVE_DIR/repo.git" update-server-info
# python:3-alpine: official image, read-only mount, ephemeral, isolated on the
# kind network only — used solely to `python -m http.server` static files.
docker rm -f "$GIT_CTR" >/dev/null 2>&1 || true
docker run -d --name "$GIT_CTR" --network "$KIND_NET" \
  -v "$SERVE_DIR:/srv:ro" -w /srv python:3-alpine \
  python -m http.server "$GIT_PORT" >/dev/null
LOCAL_REPO_URL="http://${GIT_CTR}:${GIT_PORT}/repo.git"
echo "    git mirror: $LOCAL_REPO_URL (branch $BRANCH)"

echo "==> [local] Creating kind cluster '$CLUSTER_NAME' (default CNI off, Calico owns NetworkPolicy)"
kind create cluster --name "$CLUSTER_NAME" \
  --config "$REPO_ROOT/scripts/e2e/kind/kind-calico.yaml" --wait 0s

echo "==> [local] Installing Calico (NetworkPolicy-enforcing CNI)"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl -n kube-system rollout status deployment/coredns --timeout=180s

echo "==> [local] Running gitops-golden-path.sh (policies delivered by ArgoCD from the local mirror)"
REPO_URL="$LOCAL_REPO_URL" TARGET_REVISION="$BRANCH" \
  "$REPO_ROOT/scripts/e2e/gitops-golden-path.sh"

echo "==> [local] Negative: require-digest denies a tag-only pod (ArgoCD-delivered policy)"
"$REPO_ROOT/scripts/e2e/negative/assert-require-digest.sh"

echo "==> [local] Negative: default-deny NetworkPolicy blocks cross-ns traffic (ArgoCD-delivered policy)"
"$REPO_ROOT/scripts/e2e/negative/assert-default-deny.sh"

echo ""
echo "==> A2 GITOPS E2E PASSED — Kyverno + aegis-policies delivered by ArgoCD, negatives green."
