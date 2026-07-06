#!/usr/bin/env bash
# scripts/e2e/golden-path.sh
#
# B1 (epic #167 / ADR-26) — SUBSTRATE-AGNOSTIC local E2E golden-path driver.
#
# Stands up the platform golden path — ArgoCD + Kyverno + the aegis-policies
# ClusterPolicies — on an ALREADY-RUNNING Kubernetes cluster, with ZERO AWS
# creds, ZERO AWS calls, ZERO billable resources. It proves the same policy
# stack kyverno.tf installs on EKS admits/denies workloads correctly, entirely
# offline, before any A-stage (ownership inversion) touches real infrastructure.
#
# SUBSTRATE-AGNOSTIC BY DESIGN: this script takes the cluster as given via
# $KUBECONFIG and NEVER creates one, loads images into one, or assumes a CNI.
# Cluster provisioning — kind (CI gate) or k3s (B3 richer local lane) — and its
# NetworkPolicy-enforcing CNI are the caller's job. So the SAME script runs
# unchanged on kind and k3s; only the wrapper (workflow / provisioner) differs.
#
# HARNESS-LOCAL ENFORCE OVERRIDE (epic #167 open-decision 8): the ADR-10
# require-image-digest policy ships Audit by default (var.require_digest_action).
# The negative test needs it DENYING, so this HARNESS renders the chart with
# requireDigestAction=Enforce. This is a render-time overlay LOCAL to the
# harness — it does NOT touch variables.tf or the platform's production posture.
# Override via REQUIRE_DIGEST_ACTION if a caller wants Audit.
#
# Usage:
#   KUBECONFIG=/path/to/kubeconfig ./scripts/e2e/golden-path.sh
#   Requires: kubectl, helm (both honor $KUBECONFIG automatically).
#   The cluster must already exist and enforce NetworkPolicy (kind+Calico, k3s).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLICIES_CHART="$REPO_ROOT/terraform/modules/regional-stack/charts/aegis-policies"
KYVERNO_TF="$REPO_ROOT/terraform/modules/regional-stack/kyverno.tf"

# ── pinned versions ─────────────────────────────────────────────────────────
# Kyverno chart version is READ FROM kyverno.tf so this harness cannot drift from
# what the platform installs on EKS (same anti-drift discipline as
# scripts/crossplane-kind-integration.sh).
KYVERNO_CHART_VERSION="$(grep -A10 'resource "helm_release" "kyverno"' "$KYVERNO_TF" \
  | grep -oE 'version[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"' \
  | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')"
# The workload-namespace glob the policies target — read from kyverno.tf too.
WORKLOAD_NS_GLOB="$(grep -A2 'name  = "workloadNamespaceGlob"' "$KYVERNO_TF" \
  | grep -oE 'value = "[^"]+"' | head -1 | sed -E 's/value = "([^"]+)"/\1/')"
# ArgoCD chart — the platform installs ArgoCD from Terraform; B1 only needs A
# working ArgoCD to prove the golden path, so this pin is harness-local.
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-7.7.11}"

# HARNESS-LOCAL: flip require-digest to Enforce so the negative test can DENY.
# NOT the platform default (Audit) — see header.
REQUIRE_DIGEST_ACTION="${REQUIRE_DIGEST_ACTION:-Enforce}"

# The golden-path workload namespace (must match $WORKLOAD_NS_GLOB so both
# policies target it). The negative assertions run against this namespace.
E2E_NS="${E2E_NS:-aegis-e2e}"

if [ -z "$KYVERNO_CHART_VERSION" ] || [ -z "$WORKLOAD_NS_GLOB" ]; then
  echo "FATAL: could not read pinned values from kyverno.tf." >&2
  echo "  kyverno chart version : '${KYVERNO_CHART_VERSION}'" >&2
  echo "  workload ns glob      : '${WORKLOAD_NS_GLOB}'" >&2
  exit 1
fi

echo "==> Golden-path config (substrate-agnostic; cluster taken from \$KUBECONFIG):"
echo "    KUBECONFIG            : ${KUBECONFIG:-<default ~/.kube/config>}"
echo "    kyverno chart         : $KYVERNO_CHART_VERSION (read from kyverno.tf)"
echo "    argo-cd chart         : $ARGOCD_CHART_VERSION"
echo "    workload ns glob      : $WORKLOAD_NS_GLOB"
echo "    require-digest action : $REQUIRE_DIGEST_ACTION (HARNESS override; platform default Audit)"
echo "    e2e workload ns       : $E2E_NS"

# ── failure debuggability: dump cluster state on ANY non-zero exit ───────────
dump_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo ""
    echo "########################################################################"
    echo "## FAILURE (exit $rc) — dumping cluster state for debugging"
    echo "########################################################################"
    echo "--- nodes ---";            kubectl get nodes -o wide 2>/dev/null || true
    echo "--- pods -A ---";          kubectl get pods -A -o wide 2>/dev/null || true
    echo "--- clusterpolicies ---";  kubectl get clusterpolicy 2>/dev/null || true
    echo "--- netpol -n $E2E_NS ---"; kubectl get networkpolicy -n "$E2E_NS" 2>/dev/null || true
    echo "--- events (last 40) ---"
    kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -40 || true
    echo "########################################################################"
  fi
  exit "$rc"
}
trap dump_on_failure EXIT

# ── 0. preflight — the cluster must already be up and reachable ──────────────
echo "==> [0] Preflight: cluster reachable"
kubectl config current-context
kubectl cluster-info >/dev/null
kubectl get nodes

# ── 1. ArgoCD — helm install, prove the core components come up ──────────────
echo "==> [1] Installing ArgoCD (chart $ARGOCD_CHART_VERSION)"
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update argo >/dev/null
# Trim the install to the core GitOps engine: B1 only proves ArgoCD stands up.
# dex/notifications/applicationset are out of scope here (B2 adds ApplicationSets).
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd --create-namespace \
  --version "$ARGOCD_CHART_VERSION" \
  --set dex.enabled=false \
  --set notifications.enabled=false \
  --set applicationset.enabled=false \
  --set server.service.type=ClusterIP \
  --wait --timeout 8m

echo "==> [1-assert] ArgoCD core components Available"
kubectl rollout status deploy/argocd-server        -n argocd --timeout=180s
kubectl rollout status deploy/argocd-repo-server    -n argocd --timeout=180s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=180s
echo "    ArgoCD server + repo-server + application-controller are up."

# ── 2. Kyverno — SAME chart + version kyverno.tf installs on EKS ─────────────
echo "==> [2] Installing Kyverno (chart $KYVERNO_CHART_VERSION, read from kyverno.tf)"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version "$KYVERNO_CHART_VERSION" \
  --wait --timeout 8m

echo "==> [2-assert] Kyverno admission controller Available"
kubectl rollout status deploy/kyverno-admission-controller -n kyverno --timeout=180s
kubectl rollout status deploy/kyverno-background-controller -n kyverno --timeout=180s
echo "    Kyverno admission + background controllers are up."

# ── 3. aegis-policies — helm template | kubectl apply (Enforce overlay) ──────
# helm template + kubectl apply (NOT terraform: terraform needs AWS creds/state;
# this harness needs NEITHER). The Enforce override is HARNESS-LOCAL (see header).
echo "==> [3] Rendering + applying aegis-policies (requireDigestAction=$REQUIRE_DIGEST_ACTION)"
RENDERED="$(mktemp)"
helm template aegis-policies "$POLICIES_CHART" \
  --set workloadNamespaceGlob="$WORKLOAD_NS_GLOB" \
  --set requireDigestAction="$REQUIRE_DIGEST_ACTION" > "$RENDERED"
kubectl apply -f "$RENDERED"

echo "==> [3-assert] ClusterPolicies Ready"
kubectl wait --for=condition=Ready clusterpolicy/require-image-digest                 --timeout=120s
kubectl wait --for=condition=Ready clusterpolicy/default-deny-networkpolicy-baseline  --timeout=120s
echo "    require-image-digest + default-deny-networkpolicy-baseline are Ready."

# ── 4. the aegis-e2e workload namespace (matches $WORKLOAD_NS_GLOB) ──────────
echo "==> [4] Creating labelled workload namespace $E2E_NS"
kubectl create namespace "$E2E_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$E2E_NS" \
  aegis.binhsu.org/managed-by=e2e-golden-path \
  aegis.binhsu.org/profile=ephemeral \
  --overwrite
kubectl get namespace "$E2E_NS" --show-labels

# ── 5. barrier: require-digest Enforce is ACTUALLY live (no webhook race) ─────
# Kyverno registers its validating webhook asynchronously after the policy is
# Ready. Server-side dry-run a tag-only Pod and block until it is REJECTED — this
# guarantees the negative tests run against a live Enforce webhook, not a gap.
if [ "$REQUIRE_DIGEST_ACTION" = "Enforce" ]; then
  echo "==> [5] Waiting for require-digest Enforce webhook to actually deny"
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

# ── 6. barrier: default-deny NetworkPolicy generated into the workload ns ─────
# The generate policy fires on namespace creation; poll until Kyverno has stamped
# the NetworkPolicy so the negative assertions don't race the generator.
echo "==> [6] Waiting for the generated default-deny NetworkPolicy in $E2E_NS"
ok=0
for _ in $(seq 1 30); do
  if kubectl get networkpolicy aegis-default-deny -n "$E2E_NS" >/dev/null 2>&1; then ok=1; break; fi
  sleep 4
done
[ "$ok" = 1 ] || { echo "    FAIL: aegis-default-deny NetworkPolicy was never generated."; exit 1; }
echo "    aegis-default-deny NetworkPolicy generated into $E2E_NS."

echo ""
echo "==> GOLDEN PATH UP (zero AWS spend):"
echo "    [1] ArgoCD core components Available"
echo "    [2] Kyverno admission + background controllers Available"
echo "    [3] aegis-policies ClusterPolicies Ready (require-digest=$REQUIRE_DIGEST_ACTION)"
echo "    [4] $E2E_NS namespace created + labelled"
echo "    [5] require-digest Enforce webhook confirmed denying (if Enforce)"
echo "    [6] default-deny NetworkPolicy generated into $E2E_NS"
echo "    Next: run scripts/e2e/negative/assert-*.sh against \$KUBECONFIG."
