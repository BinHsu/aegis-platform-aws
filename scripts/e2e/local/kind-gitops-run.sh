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
GIT_PORT=9418          # git daemon default (git:// protocol)
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

echo "==> [local] Building a dumb-HTTP git mirror of worktree HEAD ($BRANCH)"
# A bare mirror of the committed branch. Dumb HTTP just needs static files +
# update-server-info; ArgoCD's git client clones it read-only.
git clone --quiet --bare "$REPO_ROOT" "$SERVE_DIR/repo.git"
git -C "$SERVE_DIR/repo.git" update-server-info

echo "==> [local] Creating kind cluster '$CLUSTER_NAME' (default CNI off, Calico owns NetworkPolicy)"
kind create cluster --name "$CLUSTER_NAME" \
  --config "$REPO_ROOT/scripts/e2e/kind/kind-calico.yaml" --wait 0s

echo "==> [local] Installing Calico (NetworkPolicy-enforcing CNI)"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.2/manifests/calico.yaml
kubectl -n kube-system rollout status daemonset/calico-node --timeout=300s
kubectl wait --for=condition=Ready nodes --all --timeout=180s
kubectl -n kube-system rollout status deployment/coredns --timeout=180s

# ── Serve the mirror from an IN-CLUSTER git daemon (git:// smart protocol) ────
# NOT a sibling docker container: kind's cluster DNS does not resolve docker
# container names, and a container on the kind bridge can land inside Calico's
# 192.168.0.0/16 pod CIDR (IP collision → unroutable). An in-cluster Service
# gives ArgoCD's repo-server clean cluster-DNS + pod-network routing.
# WHY git daemon (git://) not dumb-HTTP: a plain `git clone` over a static HTTP
# server works, but ArgoCD's repo-server manifest-gen path errors "unexpected
# EOF" against dumb-HTTP (its smart→dumb fallback is not clean). git daemon
# speaks the SMART git protocol unambiguously — ArgoCD syncs it reliably.
# alpine/git: small maintained image with git; ephemeral, read-only repo, isolated
# to this throwaway cluster. Pod waits for /srv/.ready so we kubectl cp the repo
# in before the daemon exports it.
echo "==> [local] Serving the mirror in-cluster via git daemon (svc a2-git.$GIT_NS:$GIT_PORT)"
kubectl create namespace "$GIT_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "$GIT_NS" -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: a2-git
spec:
  replicas: 1
  selector: { matchLabels: { app: a2-git } }
  template:
    metadata: { labels: { app: a2-git } }
    spec:
      containers:
        - name: git
          image: alpine/git
          imagePullPolicy: IfNotPresent
          # alpine/git splits the daemon into the git-daemon apk package (no
          # backticks here: unquoted heredoc would run them) — install it, then
          # wait for the repo (kubectl cp'd) and export it.
          command: ["sh", "-c", "apk add --no-cache git-daemon >/dev/null 2>&1; until [ -f /srv/.ready ]; do sleep 1; done; exec git daemon --verbose --reuseaddr --listen=0.0.0.0 --port=$GIT_PORT --base-path=/srv --export-all --enable=upload-pack"]
          ports: [{ containerPort: $GIT_PORT }]
          volumeMounts: [{ name: srv, mountPath: /srv }]
      volumes: [{ name: srv, emptyDir: {} }]
---
apiVersion: v1
kind: Service
metadata:
  name: a2-git
spec:
  selector: { app: a2-git }
  ports: [{ port: $GIT_PORT, targetPort: $GIT_PORT }]
YAML
kubectl -n "$GIT_NS" rollout status deploy/a2-git --timeout=120s
GIT_POD="$(kubectl -n "$GIT_NS" get pod -l app=a2-git -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$GIT_NS" cp "$SERVE_DIR/repo.git" "$GIT_POD:/srv/repo.git"
kubectl -n "$GIT_NS" exec "$GIT_POD" -- touch /srv/.ready
LOCAL_REPO_URL="git://a2-git.$GIT_NS.svc.cluster.local:$GIT_PORT/repo.git"
echo "    git mirror in-cluster: $LOCAL_REPO_URL (branch $BRANCH)"

echo "==> [local] Running gitops-golden-path.sh (policies delivered by ArgoCD from the local mirror)"
REPO_URL="$LOCAL_REPO_URL" TARGET_REVISION="$BRANCH" \
  "$REPO_ROOT/scripts/e2e/gitops-golden-path.sh"

echo "==> [local] Negative: require-digest denies a tag-only pod (ArgoCD-delivered policy)"
"$REPO_ROOT/scripts/e2e/negative/assert-require-digest.sh"

echo "==> [local] Negative: default-deny NetworkPolicy blocks cross-ns traffic (ArgoCD-delivered policy)"
"$REPO_ROOT/scripts/e2e/negative/assert-default-deny.sh"

echo "==> [local] A4: argo-rollouts CRD established before a Rollout workload syncs (ArgoCD-delivered controller)"
"$REPO_ROOT/scripts/e2e/assert-argo-rollouts.sh"

echo ""
echo "==> GITOPS E2E PASSED — Kyverno + aegis-policies + argo-rollouts delivered by ArgoCD, negatives green."
