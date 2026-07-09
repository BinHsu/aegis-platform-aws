#!/usr/bin/env bash
# scripts/e2e/crossplane-gitops-golden-path.sh
#
# A3 (epic #167 / ADR-25, #175) — GITOPS-DELIVERY driver for the Crossplane v2
# XBucket stack.
#
# Sibling of scripts/crossplane-kind-integration.sh (the direct helm/kubectl
# reference lane) and of scripts/e2e/gitops-golden-path.sh (the A2 policy driver).
# Same end-state the direct test asserts — crossplane core + providers + XRD +
# Composition live on the cluster, an example XBucket composes a child Bucket MR —
# but it proves the A3 OWNERSHIP INVERSION: the whole stack arrives THROUGH ArgoCD
# (three app-of-apps children: core wave 0 -> definitions wave 1 -> config wave 2),
# NOT through `helm install crossplane` + `helm template | kubectl apply`.
#
# WHAT THIS PROVES THAT THE DIRECT TEST CANNOT:
#   1. The three GitOps children under gitops/platform-addons/addons/crossplane/
#      are valid ArgoCD manifests and sync clean.
#   2. retry-until-Healthy REPLACES the deleted `time_sleep 300s`: the wave-2
#      ClusterProviderConfig app is seeded WITHOUT waiting for the provider — its
#      first sync fails (aws.m.upbound.io CRD absent), ArgoCD retries with backoff,
#      and it converges the moment provider-family-aws is Healthy. No stopwatch.
#   3. The definitions ApplicationSet consumes the FACTS BRIDGE (region/accountId
#      from the in-cluster `cluster` Secret annotations, epic #167 A1) instead of
#      TF-set Helm values — so the git manifest stays cluster-agnostic.
#
# HARD CONSTRAINT (same as the direct test): no AWS creds. The S3 provider pod
# runs WITHOUT credentials by design; we assert up to Bucket MR OBJECT creation,
# never a real S3 reconcile. Shape-only account/region in the facts Secret.
#
# SUBSTRATE-AGNOSTIC (same contract as the A2 driver): the cluster is taken via
# $KUBECONFIG; this script never creates one. Crossplane needs no NetworkPolicy
# CNI, so plain kind (kindnet) is fine — unlike the A2 golden path.
#
# GIT SOURCE ArgoCD reads the in-repo chart + child apps from:
#   REPO_URL        (default: the public GitHub repo)
#   TARGET_REVISION (default: main)
# For a pre-merge / local run, point these at a branch or a locally-served mirror
# (scripts/e2e/local/kind-crossplane-gitops-run.sh serves this worktree so nothing
# has to be pushed). kind-in-CI against the pushed branch stays the real gate.
#
# Usage:
#   KUBECONFIG=... REPO_URL=... TARGET_REVISION=... ./scripts/e2e/crossplane-gitops-golden-path.sh
#   Requires: kubectl, helm, yq (mikefarah v4).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ADDONS_DIR="$REPO_ROOT/gitops/platform-addons/addons/crossplane"
CORE_APP="$ADDONS_DIR/applicationset-core.yaml"
DEFS_APPSET="$ADDONS_DIR/applicationset-definitions.yaml"
PC_APP="$ADDONS_DIR/applicationset-providerconfig.yaml"
CHART="$REPO_ROOT/terraform/modules/regional-stack/charts/aegis-xrds-v2"
NS=crossplane-system
ARGOCD_NS=argocd

# ── git source ArgoCD reads the app-of-apps children from ───────────────────
REPO_URL="${REPO_URL:-https://github.com/BinHsu/aegis-platform-aws}"
TARGET_REVISION="${TARGET_REVISION:-main}"

# ── pinned versions ─────────────────────────────────────────────────────────
# ArgoCD chart — harness-local pin (the platform installs ArgoCD from Terraform;
# this harness only needs A working ArgoCD). Same default as the A2 driver.
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.11}"

# ── facts-bridge shape values (SHAPE only — no AWS is contacted) ─────────────
# Mirror the annotations gitops-bootstrap.tf writes onto the real cluster Secret.
FACTS_CLUSTER_NAME="${FACTS_CLUSTER_NAME:-aegis-xbucket-v2}"
FACTS_REGION="${FACTS_REGION:-eu-central-1}"
FACTS_ACCOUNT_ID="${FACTS_ACCOUNT_ID:-123456789012}"

# ── version parity: read pins FROM SOURCE so this test cannot drift ─────────
# Crossplane core chart version — the `targetRevision:` in the GitOps core app
# (was read from crossplane.tf before A3 moved the install to GitOps).
CROSSPLANE_CHART_VERSION="$(yq eval '.spec.template.spec.source.targetRevision' "$CORE_APP")"
PROVIDER_FAMILY_PKG="$(grep -oE 'xpkg\.upbound\.io/upbound/provider-family-aws:v[0-9.]+' "$CHART/templates/providers.yaml" | head -1)"
PROVIDER_S3_PKG="$(grep -oE 'xpkg\.upbound\.io/upbound/provider-aws-s3:v[0-9.]+' "$CHART/templates/providers.yaml" | head -1)"
FUNCTION_PKG="$(grep -oE 'xpkg\.crossplane\.io/crossplane-contrib/function-patch-and-transform:v[0-9.]+' "$CHART/templates/function-patch-and-transform.yaml" | head -1)"

if [ -z "$CROSSPLANE_CHART_VERSION" ] || [ "$CROSSPLANE_CHART_VERSION" = "null" ] || \
   [ -z "$PROVIDER_FAMILY_PKG" ] || [ -z "$PROVIDER_S3_PKG" ] || [ -z "$FUNCTION_PKG" ]; then
  echo "FATAL: could not read pinned versions from source (core app / chart)." >&2
  echo "  crossplane chart : '${CROSSPLANE_CHART_VERSION}'" >&2
  echo "  family provider  : '${PROVIDER_FAMILY_PKG}'" >&2
  echo "  s3 provider      : '${PROVIDER_S3_PKG}'" >&2
  echo "  function         : '${FUNCTION_PKG}'" >&2
  exit 1
fi

echo "==> A3 GitOps-delivery config (substrate-agnostic; cluster from \$KUBECONFIG):"
echo "    KUBECONFIG            : ${KUBECONFIG:-<default ~/.kube/config>}"
echo "    repo URL             : $REPO_URL"
echo "    target revision      : $TARGET_REVISION"
echo "    argo-cd chart        : $ARGOCD_CHART_VERSION"
echo "    crossplane core chart : $CROSSPLANE_CHART_VERSION (read from core app)"
echo "    provider-family-aws  : $PROVIDER_FAMILY_PKG"
echo "    provider-aws-s3      : $PROVIDER_S3_PKG"
echo "    function-p-a-t       : $FUNCTION_PKG"
echo "    facts (SHAPE only)   : cluster=$FACTS_CLUSTER_NAME region=$FACTS_REGION account=$FACTS_ACCOUNT_ID"

# ── failure debuggability: dump ArgoCD + crossplane state on ANY non-zero exit
dump_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo ""
    echo "########################################################################"
    echo "## FAILURE (exit $rc) — dumping GitOps + crossplane state for debugging"
    echo "########################################################################"
    echo "--- applications -n argocd ---";  kubectl get applications,applicationsets -n "$ARGOCD_NS" -o wide 2>/dev/null || true
    for a in crossplane-in-cluster crossplane-xrds-definitions-in-cluster crossplane-providerconfig-in-cluster; do
      echo "--- app: $a ---"
      kubectl get application "$a" -n "$ARGOCD_NS" \
        -o jsonpath='{.status.sync.status} {.status.health.status} | ops:{.status.operationState.phase} {.status.operationState.message}{"\n"}{range .status.conditions[*]}  cond {.type}: {.message}{"\n"}{end}' 2>/dev/null || true
    done
    echo "--- pods -n $NS ---";             kubectl get pods -n "$NS" -o wide 2>/dev/null || true
    echo "--- providers ---";               kubectl get providers.pkg.crossplane.io 2>/dev/null || true
    echo "--- functions ---";               kubectl get functions.pkg.crossplane.io 2>/dev/null || true
    echo "--- MRAP ---";                     kubectl get managedresourceactivationpolicy 2>/dev/null || true
    echo "--- ns labels ---";                kubectl get ns "$NS" -o jsonpath='{.metadata.labels}' 2>/dev/null || true; echo
    echo "--- events -n $NS (last) ---";      kubectl get events -n "$NS" --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
    echo "########################################################################"
  fi
  exit "$rc"
}
trap dump_on_failure EXIT

# helper: wait until an Application reports a given HEALTH, polling ArgoCD.
wait_app() {
  local app="$1" want_health="${2:-Healthy}" timeout="${3:-600}"
  echo "    waiting for Application/$app -> health=$want_health (<= ${timeout}s)"
  local t=0 h s
  while [ "$t" -lt "$timeout" ]; do
    h="$(kubectl get application "$app" -n "$ARGOCD_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    s="$(kubectl get application "$app" -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    if [ "$h" = "$want_health" ]; then
      echo "    Application/$app is health=$h (sync=$s)"; return 0
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

# ── 1. ArgoCD (server + repo-server + application-controller + appset) ───────
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
kubectl rollout status deploy/argocd-server                      -n "$ARGOCD_NS" --timeout=180s
kubectl rollout status deploy/argocd-repo-server                 -n "$ARGOCD_NS" --timeout=180s
kubectl rollout status deploy/argocd-applicationset-controller   -n "$ARGOCD_NS" --timeout=180s
kubectl rollout status statefulset/argocd-application-controller -n "$ARGOCD_NS" --timeout=180s
echo "    ArgoCD server + repo-server + applicationset + application-controller up."

# ── 2. Facts bridge — the in-cluster `cluster` Secret the definitions ─────────
#      ApplicationSet reads region/accountId from (mirrors gitops-bootstrap.tf).
echo "==> [2] Seeding facts-bridge cluster Secret (SHAPE-only account/region)"
kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: aegis-cluster-local
  namespace: $ARGOCD_NS
  labels:
    argocd.argoproj.io/secret-type: cluster
  annotations:
    aegis.binhsu.org/cluster-name: "$FACTS_CLUSTER_NAME"
    aegis.binhsu.org/region: "$FACTS_REGION"
    aegis.binhsu.org/account-id: "$FACTS_ACCOUNT_ID"
    aegis.binhsu.org/profile: "ephemeral"
type: Opaque
stringData:
  name: in-cluster
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
YAML

# ── 3. Wave 0 — seed the crossplane CORE ApplicationSet; ArgoCD installs core ─
# Core is an ApplicationSet gated on the facts Secret (created in step 2). It uses
# the PUBLIC crossplane chart (no repoURL rewrite needed). The generated app
# creates crossplane-system with the restricted PSA labels via
# managedNamespaceMetadata.
echo "==> [3] Wave 0: seeding crossplane core ApplicationSet (ArgoCD installs the crossplane-core chart)"
kubectl apply -f "$CORE_APP"
CORE_APP_NAME="crossplane-in-cluster"
echo "    waiting for the core ApplicationSet to generate Application/$CORE_APP_NAME"
ok=0
for _ in $(seq 1 30); do
  kubectl get application "$CORE_APP_NAME" -n "$ARGOCD_NS" >/dev/null 2>&1 && { ok=1; break; }
  sleep 4
done
[ "$ok" = 1 ] || { echo "    FAIL: core ApplicationSet never generated Application/$CORE_APP_NAME (facts Secret missing?)."; exit 1; }
wait_app "$CORE_APP_NAME" Healthy 600
kubectl wait deploy/crossplane              -n "$NS" --for=condition=Available --timeout=180s
kubectl wait deploy/crossplane-rbac-manager -n "$NS" --for=condition=Available --timeout=180s
echo "    crossplane core Available (delivered by ArgoCD)."

# ── 3-assert. crossplane-system carries the restricted PSA labels ArgoCD set ──
echo "==> [3-assert] crossplane-system PSA=restricted (managedNamespaceMetadata)"
for k in enforce audit warn; do
  v="$(kubectl get ns "$NS" -o jsonpath="{.metadata.labels.pod-security\\.kubernetes\\.io/$k}" 2>/dev/null || true)"
  [ "$v" = "restricted" ] || { echo "    FAIL: ns label pod-security.kubernetes.io/$k='$v' (want restricted)"; exit 1; }
done
echo "    crossplane-system enforce/audit/warn = restricted (set by ArgoCD at CreateNamespace)."

# ── 4. Wave 1 + Wave 2 — seed definitions (ApplicationSet) AND providerconfig ─
# TOGETHER, WITHOUT waiting for the provider to be Healthy first. This is the
# retry-until-Healthy proof: providerconfig's first sync fails (aws.m.upbound.io
# CRD absent), ArgoCD retries, and it converges when the family provider is
# Healthy — the deleted time_sleep 300s, replaced by a condition-driven loop.
# Rewrite the in-repo source coords (repoURL/targetRevision) to the branch/mirror
# under test, exactly as gitops-golden-path.sh does for the root app.
echo "==> [4] Wave 1+2: seeding definitions ApplicationSet + providerconfig (no time gate)"
REPO_URL="$REPO_URL" TARGET_REVISION="$TARGET_REVISION" \
  yq eval '.spec.template.spec.source.repoURL = env(REPO_URL)
         | .spec.template.spec.source.targetRevision = env(TARGET_REVISION)' "$DEFS_APPSET" \
  | kubectl apply -f -
REPO_URL="$REPO_URL" TARGET_REVISION="$TARGET_REVISION" \
  yq eval '.spec.template.spec.source.repoURL = env(REPO_URL)
         | .spec.template.spec.source.targetRevision = env(TARGET_REVISION)' "$PC_APP" \
  | kubectl apply -f -

# The ApplicationSet generates one Application from the facts Secret
# (nameNormalized of "in-cluster").
DEFS_APP="crossplane-xrds-definitions-in-cluster"
echo "    waiting for the definitions ApplicationSet to generate Application/$DEFS_APP"
ok=0
for _ in $(seq 1 30); do
  kubectl get application "$DEFS_APP" -n "$ARGOCD_NS" >/dev/null 2>&1 && { ok=1; break; }
  sleep 4
done
[ "$ok" = 1 ] || { echo "    FAIL: ApplicationSet never generated Application/$DEFS_APP."; exit 1; }
echo "    ApplicationSet generated Application/$DEFS_APP (facts bridge consumed)."

# Wave 1 — definitions app Healthy: providers + function reach Healthy under the
# restricted PSA (this is the DRC-securityContext fidelity assertion — a wrong DRC
# would leave the pods rejected and never Healthy).
echo "==> [5] Wave 1: definitions app Healthy (providers + function under restricted PSA)"
wait_app "$DEFS_APP" Healthy 600
kubectl wait --for=condition=Healthy function.pkg.crossplane.io/function-patch-and-transform --timeout=300s
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/upbound-provider-family-aws  --timeout=300s
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/provider-aws-s3              --timeout=300s
echo "    function + both providers Healthy (delivered by ArgoCD, restricted PSA)."

# Assert NO PSA restricted-violation events surfaced on the provider/function pods
# (the prod 2026-06-18 / fix-B #2a signature — must stay clean under GitOps too).
PSA_VIOL="$(kubectl get events -n "$NS" --field-selector reason=FailedCreate \
  -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -c 'violates PodSecurity' || true)"
if [ "${PSA_VIOL:-0}" -ne 0 ]; then
  echo "    FAIL: $PSA_VIOL PodSecurity restricted violation event(s) on crossplane pods."
  kubectl get events -n "$NS" --field-selector reason=FailedCreate
  exit 1
fi
echo "    No 'violates PodSecurity restricted' events — DRC securityContext admits the pods."

# Wave 2 — providerconfig app converged via retry-until-Healthy (NOT a sleep).
echo "==> [6] Wave 2: providerconfig converged via retry-until-Healthy (time_sleep replacement)"
wait_app crossplane-providerconfig-in-cluster Healthy 600
kubectl wait --for condition=established crd/clusterproviderconfigs.aws.m.upbound.io --timeout=60s
kubectl get clusterproviderconfig default -o jsonpath='{.metadata.name}: source={.spec.credentials.source}{"\n"}'
echo "    ClusterProviderConfig applied AFTER provider Healthy — retry converged it, no fixed wait."

# ── 7-assert-b. MRAP activated ONLY the S3 MRDs (no CRD explosion) ──────────
echo "==> [7] MRAP activated ONLY *.s3.aws.m.upbound.io — no CRD explosion"
ok=0
for _ in $(seq 1 30); do
  if kubectl get crd buckets.s3.aws.m.upbound.io >/dev/null 2>&1; then ok=1; break; fi
  sleep 4
done
[ "$ok" = 1 ] || { echo "    FAIL: buckets.s3.aws.m.upbound.io CRD never established"; exit 1; }
kubectl wait --for condition=established crd/buckets.s3.aws.m.upbound.io --timeout=60s
if kubectl get crds -o name 2>/dev/null | grep -q '\.ec2\.aws\.m\.upbound\.io'; then
  echo "    FAIL: a *.ec2.aws.m.upbound.io CRD exists — CRD explosion / wrong activation."; exit 1
fi
echo "    OK: buckets.s3.aws.m.upbound.io established; no *.ec2.* CRD — MRAP scoped to S3."

# ── 8-assert-c. XRD establishes, XR applies, Composition produces a Bucket MR ─
echo "==> [8] XBucket XRD Established; example XR composes a child Bucket MR"
kubectl wait --for condition=established crd/xbuckets.platform.aegis.io --timeout=120s
echo "    XRD Established (xbuckets.platform.aegis.io)."
XR_NS="$(grep -E '^\s*namespace:' "$CHART/examples/xbucket.yaml" | head -1 | awk '{print $2}')"
XR_NS="${XR_NS:-default}"
kubectl create namespace "$XR_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$CHART/examples/xbucket.yaml"
echo "    applied example XBucket XR (namespace $XR_NS)."
ok=0
for _ in $(seq 1 45); do
  n="$(kubectl get buckets.s3.aws.m.upbound.io -n "$XR_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -ge 1 ]; then ok=1; break; fi
  sleep 4
done
[ "$ok" = 1 ] || { echo "    FAIL: the Composition never produced a Bucket MR."; kubectl describe xbucket -n "$XR_NS" 2>/dev/null | tail -40; exit 1; }
echo "    OK: Composition produced child Bucket MR(s) — pipeline ran LIVE via ArgoCD delivery:"
kubectl get buckets.s3.aws.m.upbound.io -n "$XR_NS" -o wide 2>/dev/null | sed 's/^/      /'
echo "    (MR is unsynced by design — no AWS creds; we assert creation, not real reconcile.)"

echo ""
echo "==> A3 GITOPS CROSSPLANE GOLDEN PATH UP (stack delivered by ArgoCD, zero AWS spend):"
echo "    [3] wave 0: crossplane core Available; crossplane-system PSA=restricted (managedNamespaceMetadata)"
echo "    [5] wave 1: definitions ApplicationSet (facts bridge) -> providers + function Healthy, no PSA violations"
echo "    [6] wave 2: ClusterProviderConfig converged via retry-until-Healthy (time_sleep 300s REPLACED)"
echo "    [7] MRAP activated ONLY *.s3.aws.m.upbound.io (no CRD explosion)"
echo "    [8] XRD Established; example XR composed a child Bucket MR object (live pipeline)"
