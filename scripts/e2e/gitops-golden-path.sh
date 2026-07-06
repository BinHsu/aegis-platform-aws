#!/usr/bin/env bash
# scripts/e2e/gitops-golden-path.sh
#
# A2 (epic #167 / ADR-25) — GITOPS-DELIVERY golden-path driver.
#
# Sibling of scripts/e2e/golden-path.sh (B1). Same end-state — ArgoCD + Kyverno +
# the aegis-policies ClusterPolicies live on the cluster — but proves the A2
# OWNERSHIP INVERSION: the policy stack now arrives THROUGH ArgoCD (the app-of-
# apps root → child Applications → sync-waves), NOT through a direct
# `helm install kyverno` + `helm template aegis-policies | kubectl apply`.
#
# B1 proved the policies are correct. THIS proves the DELIVERY MECHANISM is
# correct: seed only the app-of-apps root, and ArgoCD stands up Kyverno (wave 0)
# then the policies (wave 1) on its own. The SAME negative assertions
# (scripts/e2e/negative/assert-*.sh) then run unchanged — that is the A2 proof.
#
# This is the PATTERN A3–A6 reuse: each adds an addons/<name>/ Application under
# the same root; this driver already syncs "whatever the root enumerates".
#
# SUBSTRATE-AGNOSTIC (same contract as B1): the cluster is taken via $KUBECONFIG;
# this script never creates one, and it needs a NetworkPolicy-enforcing CNI for
# the default-deny behavioural test (kind+Calico / k3s). Cluster + CNI are the
# caller's job.
#
# GIT SOURCE: ArgoCD needs a git repo to read gitops/platform-addons from.
#   REPO_URL        (default: the public GitHub repo)
#   TARGET_REVISION (default: main)
# For a pre-merge / local run, point these at a branch or a locally-served mirror
# (see scripts/e2e/local/kind-gitops-run.sh for the kind wrapper that serves this
# worktree over the kind docker network so nothing has to be pushed).
#
# HARNESS-LOCAL ENFORCE OVERRIDE (epic #167 decision #8): the committed
# aegis-policies Application ships requireDigestAction=Audit (production posture).
# The negative test needs it DENYING, so this harness patches the Application's
# helm parameters to Enforce AFTER ArgoCD creates it — the GitOps analog of B1's
# render-time `--set requireDigestAction=Enforce`. It does NOT change git.
#
# Usage:
#   KUBECONFIG=... REPO_URL=... TARGET_REVISION=... ./scripts/e2e/gitops-golden-path.sh
#   Requires: kubectl, helm.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ROOT_APP="$REPO_ROOT/gitops/platform-addons/root-app.yaml"

# ── git source ArgoCD reads the app-of-apps from ────────────────────────────
REPO_URL="${REPO_URL:-https://github.com/BinHsu/aegis-platform-aws}"
TARGET_REVISION="${TARGET_REVISION:-main}"

# ── pinned versions ─────────────────────────────────────────────────────────
# ArgoCD chart — harness-local pin (the platform installs ArgoCD from Terraform;
# this harness only needs A working ArgoCD). Same default as B1's golden-path.sh.
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.11}"
# HARNESS-LOCAL: flip require-digest to Enforce so the negative test can DENY.
REQUIRE_DIGEST_ACTION="${REQUIRE_DIGEST_ACTION:-Enforce}"
# Golden-path workload namespace (must match the policies' aegis-* glob).
E2E_NS="${E2E_NS:-aegis-e2e}"
ARGOCD_NS="argocd"

echo "==> GitOps golden-path config (substrate-agnostic; cluster from \$KUBECONFIG):"
echo "    KUBECONFIG            : ${KUBECONFIG:-<default ~/.kube/config>}"
echo "    repo URL             : $REPO_URL"
echo "    target revision      : $TARGET_REVISION"
echo "    argo-cd chart        : $ARGOCD_CHART_VERSION"
echo "    require-digest action : $REQUIRE_DIGEST_ACTION (HARNESS override; platform default Audit)"
echo "    e2e workload ns       : $E2E_NS"

# ── failure debuggability: dump ArgoCD + policy state on ANY non-zero exit ────
dump_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo ""
    echo "########################################################################"
    echo "## FAILURE (exit $rc) — dumping GitOps + cluster state for debugging"
    echo "########################################################################"
    echo "--- applications -n argocd ---"; kubectl get applications -n "$ARGOCD_NS" -o wide 2>/dev/null || true
    echo "--- app: platform-addons ---";   kubectl get application platform-addons -n "$ARGOCD_NS" -o yaml 2>/dev/null | grep -A40 'status:' | head -50 || true
    echo "--- app: kyverno ---";           kubectl get application kyverno -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status} {.status.health.status} {.status.conditions}' 2>/dev/null || true; echo
    echo "--- app: aegis-policies ---";     kubectl get application aegis-policies -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status} {.status.health.status} {.status.conditions}' 2>/dev/null || true; echo
    echo "--- clusterpolicies ---";         kubectl get clusterpolicy 2>/dev/null || true
    echo "--- pods -A ---";                 kubectl get pods -A -o wide 2>/dev/null || true
    echo "--- events (last 40) ---";        kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -40 || true
    echo "########################################################################"
  fi
  exit "$rc"
}
trap dump_on_failure EXIT

# helper: wait until an Application reports a given HEALTH, polling ArgoCD.
# HEALTH — not sync — is the readiness signal we gate on. Kyverno self-mutates
# (it injects its own webhook caBundle, and ships cleanup CronJobs + generated
# resources), so ArgoCD's SYNC status for it legitimately flaps
# Synced<->Unknown/OutOfSync forever; blocking on Synced would never settle. We
# block on health=Healthy (all resources healthy) and just LOG the sync status;
# the caller's kubectl rollout/wait is the concrete object-level gate.
wait_app() {
  local app="$1" want_health="${2:-Healthy}" timeout="${3:-300}"
  echo "    waiting for Application/$app -> health=$want_health (<= ${timeout}s)"
  local t=0 h s
  while [ "$t" -lt "$timeout" ]; do
    h="$(kubectl get application "$app" -n "$ARGOCD_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    s="$(kubectl get application "$app" -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    if [ "$h" = "$want_health" ]; then
      echo "    Application/$app is health=$h (sync=$s — flap-tolerant for self-mutating operators)"; return 0
    fi
    sleep 5; t=$((t + 5))
  done
  echo "    FAIL: Application/$app never reached health=$want_health (last: sync=${s:-?}/health=${h:-?})"; return 1
}

# ── 0. preflight ─────────────────────────────────────────────────────────────
echo "==> [0] Preflight: cluster reachable"
kubectl config current-context
kubectl cluster-info >/dev/null
kubectl get nodes

# ── 1. ArgoCD (WITH the applicationset/controller needed to run app-of-apps) ──
echo "==> [1] Installing ArgoCD (chart $ARGOCD_CHART_VERSION)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
helm upgrade --install argocd argo/argo-cd \
  --namespace "$ARGOCD_NS" --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --set server.service.type=ClusterIP \
  --wait --timeout 8m
kubectl rollout status deploy/argocd-server                       -n "$ARGOCD_NS" --timeout=180s
kubectl rollout status deploy/argocd-repo-server                  -n "$ARGOCD_NS" --timeout=180s
kubectl rollout status statefulset/argocd-application-controller  -n "$ARGOCD_NS" --timeout=180s
echo "    ArgoCD server + repo-server + application-controller are up."

# ── 2. Seed ONLY the app-of-apps root — ArgoCD does the rest ─────────────────
# This is the whole point of the inversion: we apply ONE Application (the root),
# with the repoURL/targetRevision the cluster should track, and ArgoCD renders
# the kyverno (wave 0) + aegis-policies (wave 1) child Applications from git.
echo "==> [2] Seeding app-of-apps root (repoURL=$REPO_URL rev=$TARGET_REVISION)"
kubectl apply -f - <<YAML
$(REPO_URL="$REPO_URL" TARGET_REVISION="$TARGET_REVISION" \
  yq eval '.spec.source.repoURL = env(REPO_URL) | .spec.source.targetRevision = env(TARGET_REVISION)' "$ROOT_APP")
YAML

# ── 3. Wave 0 — Kyverno controller comes up via ArgoCD ───────────────────────
echo "==> [3] Wave 0: ArgoCD syncing Kyverno controller"
wait_app kyverno Healthy 600
kubectl rollout status deploy/kyverno-admission-controller  -n kyverno --timeout=180s
kubectl rollout status deploy/kyverno-background-controller -n kyverno --timeout=180s
echo "    Kyverno admission + background controllers up (delivered by ArgoCD)."

# ── 4. Harness-local Enforce override on the aegis-policies Application ───────
# GitOps analog of B1's `helm template --set requireDigestAction=Enforce`: patch
# the Application ArgoCD created so its next render uses Enforce. The committed
# git value stays Audit (production posture). Applied BEFORE waiting for wave 1
# so the policy is Ready in the Enforce shape the negative test expects.
if [ "$REQUIRE_DIGEST_ACTION" = "Enforce" ]; then
  echo "==> [4] Harness override: aegis-policies requireDigestAction=Enforce"
  # Wait for the child app object to exist (root sync creates it), then patch.
  for _ in $(seq 1 30); do
    kubectl get application aegis-policies -n "$ARGOCD_NS" >/dev/null 2>&1 && break; sleep 4
  done
  kubectl patch application aegis-policies -n "$ARGOCD_NS" --type merge -p \
    '{"spec":{"source":{"helm":{"parameters":[{"name":"requireDigestAction","value":"Enforce"}]}}}}'
fi

# ── 5. Wave 1 — aegis-policies ClusterPolicies synced by ArgoCD ──────────────
echo "==> [5] Wave 1: ArgoCD syncing aegis-policies ClusterPolicies"
wait_app aegis-policies Healthy 300
kubectl wait --for=condition=Ready clusterpolicy/require-image-digest                --timeout=120s
kubectl wait --for=condition=Ready clusterpolicy/default-deny-networkpolicy-baseline --timeout=120s
# The step-4 Enforce patch triggers an ArgoCD RE-render; the policy object may
# still carry the pre-patch Audit action for a few seconds. Poll the live
# ClusterPolicy until it actually reflects Enforce (don't race the re-sync).
if [ "$REQUIRE_DIGEST_ACTION" = "Enforce" ]; then
  echo "    waiting for require-image-digest validationFailureAction=Enforce (post-patch re-sync)"
  ok=0
  for _ in $(seq 1 36); do
    DIGEST_ACTION="$(kubectl get clusterpolicy require-image-digest -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || true)"
    [ "$DIGEST_ACTION" = "Enforce" ] && { ok=1; break; }
    kubectl -n "$ARGOCD_NS" annotate application aegis-policies argocd.argoproj.io/refresh=normal --overwrite >/dev/null 2>&1 || true
    sleep 5
  done
  [ "$ok" = 1 ] || { echo "    FAIL: require-image-digest never became Enforce (last: '$DIGEST_ACTION')."; exit 1; }
else
  DIGEST_ACTION="$(kubectl get clusterpolicy require-image-digest -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || true)"
fi
echo "    ClusterPolicies Ready via ArgoCD (require-image-digest action=$DIGEST_ACTION)."

# ── 6. workload namespace + barriers (identical to B1 golden-path.sh) ────────
echo "==> [6] Creating labelled workload namespace $E2E_NS"
kubectl create namespace "$E2E_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$E2E_NS" \
  aegis.binhsu.org/managed-by=e2e-gitops-golden-path \
  aegis.binhsu.org/profile=ephemeral --overwrite
kubectl get namespace "$E2E_NS" --show-labels

if [ "$REQUIRE_DIGEST_ACTION" = "Enforce" ]; then
  echo "==> [7] Waiting for require-digest Enforce webhook to actually deny"
  PROBE="$(mktemp)"
  cat >"$PROBE" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: require-digest-readiness-probe
  namespace: $E2E_NS
spec:
  containers:
    - name: probe
      image: busybox:1.37
YAML
  ok=0
  for _ in $(seq 1 30); do
    if ! kubectl apply --dry-run=server -f "$PROBE" >/dev/null 2>&1; then ok=1; break; fi
    sleep 4
  done
  [ "$ok" = 1 ] || { echo "    FAIL: Enforce webhook never rejected a tag-only probe."; exit 1; }
  echo "    require-digest Enforce is live (tag-only probe rejected at admission)."
fi

echo "==> [8] Waiting for the generated default-deny NetworkPolicy in $E2E_NS"
ok=0
for _ in $(seq 1 30); do
  if kubectl get networkpolicy aegis-default-deny -n "$E2E_NS" >/dev/null 2>&1; then ok=1; break; fi
  sleep 4
done
[ "$ok" = 1 ] || { echo "    FAIL: aegis-default-deny NetworkPolicy was never generated."; exit 1; }
echo "    aegis-default-deny NetworkPolicy generated into $E2E_NS."

echo ""
echo "==> GITOPS GOLDEN PATH UP (policies delivered by ArgoCD, zero AWS spend):"
echo "    [2] app-of-apps root seeded (ArgoCD rendered kyverno + aegis-policies)"
echo "    [3] wave 0: Kyverno controllers Available (via ArgoCD)"
echo "    [5] wave 1: aegis-policies ClusterPolicies Ready (via ArgoCD, action=$DIGEST_ACTION)"
echo "    [7] require-digest Enforce webhook confirmed denying (if Enforce)"
echo "    [8] default-deny NetworkPolicy generated into $E2E_NS"
echo "    Next: run scripts/e2e/negative/assert-*.sh against \$KUBECONFIG."
