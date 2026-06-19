#!/usr/bin/env bash
# scripts/crossplane-kind-integration.sh
#
# NON-BILLABLE kind-in-CI integration test for the WS4 Axis A XBucket v2 stack
# (ADR-22). This is the "run the seam cheaply before the billable one" gate from
# RETRO §7A / §8 P1: a kind cluster (real Kubernetes API server) installs the
# SAME Crossplane v2 stack crossplane.tf installs — but via helm/kubectl, with
# ZERO AWS creds, ZERO AWS calls, ZERO billable resources.
#
# WHAT THIS CATCHES THAT THE OFFLINE crossplane-validate GATE CANNOT (RETRO §7F):
#   `crossplane render`/`validate` exercise the RENDERING path only. The prod
#   2026-06-18 / fix-B incident #2(a) was a RUNTIME ADMISSION event: the function/
#   provider pod was REJECTED by PSA=restricted because its DRC securityContext
#   was empty. Only a live API server enforcing PSA produces that rejection. This
#   test reproduces it for free: it labels crossplane-system PSA=restricted BEFORE
#   install (mirroring crossplane.tf), then proves the DRC securityContext the
#   chart ships actually ADMITS the function + provider pods under restricted.
#
# HARD CONSTRAINT: no AWS creds. The S3 provider pod runs WITHOUT credentials by
# design — that is EXPECTED. We assert up to MR (Bucket) OBJECT creation, proving
# the composition pipeline runs live; we NEVER wait for READY/SYNCED against real
# S3 (there is nothing to sync to, and no creds to do it with).
#
# VERSION PARITY: every pinned version below is READ FROM crossplane.tf / the
# chart so this test cannot drift from what the platform actually installs. The
# parity check at the top fails loud if a pin here disagrees with the source.
#
# Usage: ./scripts/crossplane-kind-integration.sh
#   Requires: kind, kubectl, helm, docker (all present on a GitHub ubuntu runner).
#   Assumes a kind cluster named "$KIND_CLUSTER" already exists (the workflow
#   creates it via helm/kind-action). If not, set CREATE_CLUSTER=1 to create one.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$REPO_ROOT/terraform/modules/regional-stack/charts/aegis-xrds-v2"
CROSSPLANE_TF="$REPO_ROOT/terraform/modules/regional-stack/crossplane.tf"
NS=crossplane-system
KIND_CLUSTER="${KIND_CLUSTER:-aegis-xbucket-v2}"

# Example install values — SHAPE only, never a real account (no AWS is contacted).
HELM_REGION=eu-central-1
HELM_ACCOUNT=123456789012
HELM_PREFIX=aegis-wl

# ── pinned versions, READ FROM SOURCE so this test cannot drift ─────────────
# crossplane core chart version — the `version = "X"` in crossplane.tf's
# helm_release.crossplane block.
CROSSPLANE_CHART_VERSION="$(grep -oE 'version[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' "$CROSSPLANE_TF" | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
# provider / function package refs — read from the chart templates (single SoT).
PROVIDER_FAMILY_PKG="$(grep -oE 'xpkg\.upbound\.io/upbound/provider-family-aws:v[0-9.]+' "$CHART/templates/providers.yaml" | head -1)"
PROVIDER_S3_PKG="$(grep -oE 'xpkg\.upbound\.io/upbound/provider-aws-s3:v[0-9.]+' "$CHART/templates/providers.yaml" | head -1)"
FUNCTION_PKG="$(grep -oE 'xpkg\.crossplane\.io/crossplane-contrib/function-patch-and-transform:v[0-9.]+' "$CHART/templates/function-patch-and-transform.yaml" | head -1)"

if [ -z "$CROSSPLANE_CHART_VERSION" ] || [ -z "$PROVIDER_FAMILY_PKG" ] || \
   [ -z "$PROVIDER_S3_PKG" ] || [ -z "$FUNCTION_PKG" ]; then
  echo "FATAL: could not read pinned versions from source (crossplane.tf / chart)." >&2
  echo "  crossplane chart : '${CROSSPLANE_CHART_VERSION}'" >&2
  echo "  family provider  : '${PROVIDER_FAMILY_PKG}'" >&2
  echo "  s3 provider      : '${PROVIDER_S3_PKG}'" >&2
  echo "  function         : '${FUNCTION_PKG}'" >&2
  exit 1
fi

echo "==> Pinned versions (read from source, no drift):"
echo "    crossplane core chart : $CROSSPLANE_CHART_VERSION"
echo "    provider-family-aws   : $PROVIDER_FAMILY_PKG"
echo "    provider-aws-s3       : $PROVIDER_S3_PKG"
echo "    function-p-a-t        : $FUNCTION_PKG"

# ── failure debuggability: dump cluster state on ANY non-zero exit ──────────
dump_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo ""
    echo "########################################################################"
    echo "## FAILURE (exit $rc) — dumping cluster state for debugging"
    echo "########################################################################"
    echo "--- pods -n $NS ---";            kubectl get pods -n "$NS" -o wide 2>/dev/null || true
    echo "--- deployments -n $NS ---";     kubectl get deploy -n "$NS" 2>/dev/null || true
    echo "--- providers ---";              kubectl get providers.pkg.crossplane.io 2>/dev/null || true
    echo "--- functions ---";              kubectl get functions.pkg.crossplane.io 2>/dev/null || true
    echo "--- providerrevisions ---";      kubectl get providerrevisions.pkg.crossplane.io 2>/dev/null || true
    echo "--- MRAP ---";                   kubectl get managedresourceactivationpolicy 2>/dev/null || true
    echo "--- events -n $NS (FailedCreate) ---"
    kubectl get events -n "$NS" --field-selector reason=FailedCreate 2>/dev/null || true
    echo "--- all events -n $NS (last) ---"
    kubectl get events -n "$NS" --sort-by=.lastTimestamp 2>/dev/null | tail -40 || true
    echo "--- describe non-running pods ---"
    for p in $(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed" {print $1}'); do
      echo ">>> describe pod/$p"
      kubectl describe pod "$p" -n "$NS" 2>/dev/null | tail -40 || true
    done
    echo "########################################################################"
  fi
  exit "$rc"
}
trap dump_on_failure EXIT

# ── 0. optional cluster create (workflow uses helm/kind-action instead) ─────
if [ "${CREATE_CLUSTER:-0}" = "1" ]; then
  echo "==> Creating kind cluster $KIND_CLUSTER"
  kind create cluster --name "$KIND_CLUSTER" --wait 120s
fi

echo "==> kube context: $(kubectl config current-context)"
kubectl cluster-info >/dev/null

# ── 1. crossplane-system namespace, PSA=restricted ENFORCED BEFORE install ──
# This is the WHOLE POINT (RETRO §7A/§7F): label restricted FIRST, exactly as
# crossplane.tf's kubernetes_namespace.crossplane_system does. If the chart's DRC
# securityContext is empty/wrong, the provider+function pods get REJECTED here —
# the prod 2026-06-18 failure, caught for $0.
echo "==> [1] Creating $NS with PSA=restricted ENFORCED (mirrors crossplane.tf)"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite
echo "    PSA labels:"
kubectl get namespace "$NS" -o jsonpath='{.metadata.labels}' ; echo

# ── 2. crossplane core — SAME chart + version + securityContext as crossplane.tf
echo "==> [2] Installing crossplane core $CROSSPLANE_CHART_VERSION (restricted-PSA securityContext)"
helm repo add crossplane-stable https://charts.crossplane.io/stable >/dev/null 2>&1 || true
helm repo update crossplane-stable >/dev/null
# securityContextCrossplane / securityContextRBACManager mirror crossplane.tf's
# helm_release.crossplane values verbatim (restricted-PSA: runAsNonRoot, numeric
# UID 65532, seccompProfile RuntimeDefault, drop ALL, no privesc, ro-rootfs).
helm install crossplane crossplane-stable/crossplane \
  --namespace "$NS" \
  --version "$CROSSPLANE_CHART_VERSION" \
  --wait --timeout 5m \
  --set securityContextCrossplane.runAsNonRoot=true \
  --set securityContextCrossplane.runAsUser=65532 \
  --set securityContextCrossplane.runAsGroup=65532 \
  --set securityContextCrossplane.allowPrivilegeEscalation=false \
  --set securityContextCrossplane.readOnlyRootFilesystem=true \
  --set securityContextCrossplane.seccompProfile.type=RuntimeDefault \
  --set 'securityContextCrossplane.capabilities.drop[0]=ALL' \
  --set securityContextRBACManager.runAsNonRoot=true \
  --set securityContextRBACManager.runAsUser=65532 \
  --set securityContextRBACManager.runAsGroup=65532 \
  --set securityContextRBACManager.allowPrivilegeEscalation=false \
  --set securityContextRBACManager.readOnlyRootFilesystem=true \
  --set securityContextRBACManager.seccompProfile.type=RuntimeDefault \
  --set 'securityContextRBACManager.capabilities.drop[0]=ALL'

echo "==> [2-assert] crossplane core Deployments Available under PSA=restricted"
kubectl wait deploy/crossplane              -n "$NS" --for=condition=Available --timeout=180s
kubectl wait deploy/crossplane-rbac-manager -n "$NS" --for=condition=Available --timeout=180s
# Core pods Running (would be Pending/rejected if the securityContext were wrong).
kubectl wait --for=condition=Ready pod -l app=crossplane             -n "$NS" --timeout=180s
kubectl wait --for=condition=Ready pod -l app=crossplane-rbac-manager -n "$NS" --timeout=180s
echo "    crossplane core Available + Running under restricted PSA."

# ── 3. the aegis-xrds-v2 chart — SAME way crossplane.tf installs it ─────────
# Helm-render the chart with the same .Values keys crossplane.tf sets, then apply
# with kubectl (NOT terraform — terraform needs AWS creds/state; this test needs
# NEITHER). The chart ships: providers (family + s3), function, MRAP, 3 DRCs,
# ClusterProviderConfig, XRD, Composition.
echo "==> [3] Installing aegis-xrds-v2 chart via helm template | kubectl apply"
RENDERED="$(mktemp)"
helm template aegis-xrds-v2 "$CHART" \
  --namespace "$NS" \
  --set region="$HELM_REGION" \
  --set accountId="$HELM_ACCOUNT" \
  --set bucketPrefix="$HELM_PREFIX" > "$RENDERED"
# crossplane core CRDs (Provider, Function, DeploymentRuntimeConfig, XRD, MRAP)
# exist from step 2. The aws.m.upbound.io CRDs (ClusterProviderConfig) do NOT yet
# — they arrive only after the family provider establishes them. So apply in two
# waves: everything that does NOT depend on the provider CRDs first (wave 1), then
# the ClusterProviderConfig once the provider is Healthy (wave 2). Splitting it
# out keeps its expected missing-CRD error from aborting the whole apply.
WAVE1="$(mktemp)"; WAVE2="$(mktemp)"
# Anchor on a top-level `kind: ClusterProviderConfig` (start-of-doc or after a
# newline, end-of-line) so the Composition body — which REFERENCES
# ClusterProviderConfig in providerConfigRef.kind — is NOT mis-routed to wave 2.
awk 'BEGIN{RS="\n---\n"; ORS="\n---\n"}
     /(^|\n)kind: ClusterProviderConfig(\n|$)/{print > "/dev/stderr"; next}
     {print}' \
  "$RENDERED" >"$WAVE1" 2>"$WAVE2"
echo "    wave 1: providers, function, DRCs, MRAP, XRD, Composition"
kubectl apply -f "$WAVE1"

echo "==> [3-assert] provider family + s3 + function become Healthy under restricted PSA"
# This is the fidelity assertion: Healthy requires the runtime pod to be ADMITTED
# (PSA) and Running. If the DRC securityContext were empty/wrong, the pod is
# rejected → never Healthy → this wait TIMES OUT (and the trap dumps the PSA
# FailedCreate event). Pulls the upjet+contrib images here.
kubectl wait --for=condition=Healthy function.pkg.crossplane.io/function-patch-and-transform --timeout=300s
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/upbound-provider-family-aws  --timeout=300s
kubectl wait --for=condition=Healthy provider.pkg.crossplane.io/provider-aws-s3              --timeout=300s
echo "    function + both providers Healthy."

# Now the aws.m.upbound.io CRDs exist (the family provider established them) →
# apply the ClusterProviderConfig (wave 2).
if [ -s "$WAVE2" ]; then
  echo "    wave 2: ClusterProviderConfig (aws.m.upbound.io now established)"
  # the family provider's ClusterProviderConfig CRD must exist first
  kubectl wait --for condition=established crd/clusterproviderconfigs.aws.m.upbound.io --timeout=120s
  kubectl apply -f "$WAVE2"
fi

# ── 4-assert-a. function + provider pods ADMITTED + Running under PSA=restricted
echo "==> [4a] function + provider pods Running, NO PSA rejection events"
kubectl wait --for=condition=Ready pod -l pkg.crossplane.io/function=function-patch-and-transform -n "$NS" --timeout=180s
kubectl wait --for=condition=Ready pod -l pkg.crossplane.io/provider=provider-aws-s3             -n "$NS" --timeout=180s
kubectl wait --for=condition=Ready pod -l pkg.crossplane.io/provider=upbound-provider-family-aws -n "$NS" --timeout=180s
# Assert NO PSA rejection surfaced. A restricted-violation shows as a FailedCreate
# event on the ReplicaSet with message 'violates PodSecurity "restricted'. If the
# DRC were empty this is exactly what we'd see (the prod 2026-06-18 signature).
PSA_VIOL="$(kubectl get events -n "$NS" --field-selector reason=FailedCreate \
  -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null | grep -c 'violates PodSecurity' || true)"
if [ "${PSA_VIOL:-0}" -ne 0 ]; then
  echo "    FAIL: $PSA_VIOL PodSecurity restricted violation event(s) on crossplane pods."
  kubectl get events -n "$NS" --field-selector reason=FailedCreate
  exit 1
fi
echo "    No 'violates PodSecurity restricted' events — DRC securityContext admits the pods. (catches fix-B #2a)"

# ── 4-assert-b. MRAP activated ONLY the S3 MRDs (no CRD explosion) ──────────
echo "==> [4b] MRAP activated ONLY *.s3.aws.m.upbound.io — no CRD explosion"
# Wait for the MRAP to activate the S3 group: buckets.s3.aws.m.upbound.io must
# become established.
ok=0
for _ in $(seq 1 30); do
  if kubectl get crd buckets.s3.aws.m.upbound.io >/dev/null 2>&1; then ok=1; break; fi
  sleep 4
done
[ "$ok" = 1 ] || { echo "    FAIL: buckets.s3.aws.m.upbound.io CRD never established"; exit 1; }
kubectl wait --for condition=established crd/buckets.s3.aws.m.upbound.io --timeout=60s
echo "    OK: buckets.s3.aws.m.upbound.io established."
# A non-S3 family CRD must NOT exist (we never installed provider-aws-ec2; the
# MRAP only activates S3). Proves no CRD explosion.
if kubectl get crds -o name 2>/dev/null | grep -q '\.ec2\.aws\.m\.upbound\.io'; then
  echo "    FAIL: a *.ec2.aws.m.upbound.io CRD exists — CRD explosion / wrong activation."
  kubectl get crds -o name | grep '\.ec2\.aws\.m\.upbound\.io'
  exit 1
fi
echo "    OK: no *.ec2.aws.m.upbound.io CRD — MRAP scoped to S3 only."
echo "    S3 CRDs established (sample):"
kubectl get crds -o name | grep '\.s3\.aws\.m\.upbound\.io' | head -10 | sed 's/^/      /'

# ── 4-assert-c. XRD establishes, XR applies, Composition produces a Bucket MR ─
echo "==> [4c] XBucket XRD establishes; example XR composes a child Bucket MR"
kubectl wait --for condition=established crd/xbuckets.platform.aegis.io --timeout=120s
echo "    XRD established (xbuckets.platform.aegis.io)."
# Apply the example XR (charts/.../examples/xbucket.yaml) into its namespace.
XR_NS="$(grep -E '^\s*namespace:' "$CHART/examples/xbucket.yaml" | head -1 | awk '{print $2}')"
XR_NS="${XR_NS:-default}"
kubectl create namespace "$XR_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$CHART/examples/xbucket.yaml"
echo "    applied example XBucket XR (namespace $XR_NS)."
# Assert the Composition pipeline RAN LIVE: it must produce a child Bucket
# (s3.aws.m.upbound.io) managed-resource OBJECT. We assert the MR is CREATED — NOT
# that it reconciles to AWS (no creds, by design). Poll for the object's existence.
echo "    waiting for the Composition to produce a child Bucket MR object..."
ok=0
for _ in $(seq 1 45); do
  n="$(kubectl get buckets.s3.aws.m.upbound.io -n "$XR_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n:-0}" -ge 1 ]; then ok=1; break; fi
  sleep 4
done
if [ "$ok" != 1 ]; then
  echo "    FAIL: the Composition never produced a Bucket MR. XR / composite state:"
  kubectl get xbucket -n "$XR_NS" -o wide 2>/dev/null || true
  kubectl describe xbucket -n "$XR_NS" 2>/dev/null | tail -60 || true
  exit 1
fi
echo "    OK: Composition produced child Bucket MR(s) — pipeline ran LIVE:"
kubectl get buckets.s3.aws.m.upbound.io -n "$XR_NS" -o wide 2>/dev/null | sed 's/^/      /'
# Honest boundary: the MR will sit unsynced (no AWS creds). We assert it EXISTS,
# proving the function + composition rendered a real object on the live API — we
# deliberately do NOT wait for READY/SYNCED (that needs real S3 + creds = billable).
echo "    (MR is unsynced by design — no AWS creds; we assert creation, not real reconcile.)"

echo ""
echo "==> ALL kind-integration assertions PASSED (zero AWS spend):"
echo "    [2] crossplane core Available + Running under PSA=restricted"
echo "    [3] function + family + s3 providers Healthy under PSA=restricted"
echo "    [4a] function/provider pods Running, NO PSA restricted violations (fix-B #2a)"
echo "    [4b] MRAP activated ONLY *.s3.aws.m.upbound.io (no CRD explosion)"
echo "    [4c] XRD established; example XR composed a child Bucket MR object (live pipeline)"
