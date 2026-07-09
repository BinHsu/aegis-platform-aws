#!/usr/bin/env bash
# scripts/e2e/b2/assert-workload-onboarding.sh
#
# B2 (epic #167 / ADR-26) — SUBSTRATE-AGNOSTIC sample-workload onboarding driver.
#
# PRECONDITION: the GitOps golden path is already up on the cluster given by
# $KUBECONFIG (run scripts/e2e/gitops-golden-path.sh first) — ArgoCD (WITH the
# applicationset controller), Kyverno, and the aegis-policies ClusterPolicies
# with require-image-digest in Enforce; AND the in-cluster registry:2 mirror has
# been seeded with the fixture image (the runner calls registry_seed before this).
#
# WHAT IT PROVES (the A5 acceptance gate — migrate the workload ApplicationSet):
#   1. A sample workload described by a registries entry (sample-registries.json)
#      is fanned out through the SAME template + templatePatch ApplicationSet the
#      platform runs (scripts/e2e/b2/workload-applicationset.yaml, a faithful port
#      of the GitOps-resident gitops/platform-addons/addons/workloads/), producing
#      an Application that reaches Synced + Healthy AND carries the A5/A4 ordering
#      shape (sync-wave 3 + retry) on the generated Application.
#   2. The per-workload / per-account injections land on the rendered resources:
#      the always-on commonAnnotations (region + ecr-repository) AND the
#      conditional model-store ConfigMap injection (fires because the workload
#      declares engine_irsa) — while the cert / gateway-oidc guards stay OFF.
#   3. The digest-pinned workload is ADMITTED (require-digest positive) while a
#      tag-only VARIANT of the same workload is DENIED at admission (negative,
#      against a real Deployment — not just a bare Pod).
#
# GIT SOURCE (same contract as gitops-golden-path.sh):
#   REPO_URL        — repo ArgoCD reads the fixture from (default: public repo).
#   TARGET_REVISION — branch/sha (default: main). The fixture must exist there.
#
# Usage: KUBECONFIG=... REPO_URL=... TARGET_REVISION=... \
#          ./scripts/e2e/b2/assert-workload-onboarding.sh
#   Requires: kubectl, jq, yq (mikefarah v4).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APPSET_MANIFEST="$REPO_ROOT/scripts/e2e/b2/workload-applicationset.yaml"
REGISTRIES_JSON="$REPO_ROOT/sample-registries.json"

REPO_URL="${REPO_URL:-https://github.com/BinHsu/aegis-platform-aws}"
TARGET_REVISION="${TARGET_REVISION:-main}"
ARGOCD_NS="argocd"

# Harness element values (the transform argocd.tf feeds from TF vars / AWS
# outputs; here they are explicit so the kind lane exercises the same shape).
WORKLOAD_FIXTURE_PATH="${WORKLOAD_FIXTURE_PATH:-fixtures/sample-deploy/k8s/overlays/e2e}"
REGION="${REGION:-eu-central-1}"
MODEL_BUCKET="${MODEL_BUCKET:-aegis-e2e-model-store}"

# Derived — the ApplicationSet names the Application by trimming "-deploy".
WORKLOAD_REPO="aegis-sample-deploy"
APP_NAME="aegis-sample"
APP_NS="aegis-sample"

echo "==> B2 workload-onboarding config:"
echo "    KUBECONFIG       : ${KUBECONFIG:-<default>}"
echo "    repo URL         : $REPO_URL"
echo "    target revision  : $TARGET_REVISION"
echo "    fixture path     : $WORKLOAD_FIXTURE_PATH"
echo "    region inject    : $REGION"
echo "    model bucket     : $MODEL_BUCKET"

dump_on_failure() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo ""
    echo "########################################################################"
    echo "## FAILURE (exit $rc) — dumping ApplicationSet + workload state"
    echo "########################################################################"
    echo "--- applicationsets -n argocd ---"; kubectl get applicationset -n "$ARGOCD_NS" -o wide 2>/dev/null || true
    echo "--- applications -n argocd ---";     kubectl get applications -n "$ARGOCD_NS" -o wide 2>/dev/null || true
    echo "--- app $APP_NAME ---";              kubectl get application "$APP_NAME" -n "$ARGOCD_NS" -o yaml 2>/dev/null | grep -A60 '^status:' | head -70 || true
    echo "--- workloads -n $APP_NS ---";       kubectl get all,configmap -n "$APP_NS" 2>/dev/null || true
    echo "--- events -n $APP_NS ---";          kubectl get events -n "$APP_NS" --sort-by=.lastTimestamp 2>/dev/null | tail -30 || true
    echo "########################################################################"
  fi
  exit "$rc"
}
trap dump_on_failure EXIT

# ── 0. preflight — the applicationset controller must be running ──────────────
echo "==> [0] Preflight: ArgoCD applicationset controller present"
kubectl rollout status deploy/argocd-applicationset-controller -n "$ARGOCD_NS" --timeout=120s

# ── 1. build the List-generator elements from sample-registries.json ─────────
# SAME transform as terraform/modules/regional-stack/argocd.tf ::
# local.workload_list_elements — every element carries every key (empty string
# when absent) so the ApplicationSet's missingkey=error stays safe.
echo "==> [1] Building List-generator elements from $(basename "$REGISTRIES_JSON")"
ELEMENTS_FILE="$(mktemp)"
jq \
  --arg url "$REPO_URL" \
  --arg branch "$TARGET_REVISION" \
  --arg path "$WORKLOAD_FIXTURE_PATH" \
  --arg region "$REGION" \
  --arg modelBucket "$MODEL_BUCKET" \
  '.workload_registries | to_entries | map({
     repository:           .key,
     url:                  $url,
     branch:               $branch,
     path:                 $path,
     region:               $region,
     ecrAccountId:         .value.ecr_account_id,
     ecrRegion:            .value.ecr_region,
     engineServiceAccount: (.value.engine_irsa.service_account // ""),
     ingressName:          (.value.ingress_cert.ingress_name // ""),
     certArn:              "",
     modelBucket:          $modelBucket,
     cognitoIssuer:        "",
     cognitoAudience:      "",
     cognitoJwks:          ""
   })' "$REGISTRIES_JSON" > "$ELEMENTS_FILE"
echo "    elements:"; jq -c '.[]' "$ELEMENTS_FILE" | sed 's/^/      /'

# ── 2. render + apply the AppProject + ApplicationSet ────────────────────────
# Inject the elements into the ApplicationSet doc (JSON is valid YAML → load()).
echo "==> [2] Applying AppProject + ApplicationSet (elements injected)"
RENDERED="$(mktemp)"
ELEMENTS_FILE="$ELEMENTS_FILE" yq eval-all '
  (select(.kind == "ApplicationSet").spec.generators[0].list.elements) = load(env(ELEMENTS_FILE))
' "$APPSET_MANIFEST" > "$RENDERED"
kubectl apply -f "$RENDERED"

# ── 3. wait for the generated Application to appear, then Synced + Healthy ────
echo "==> [3] Waiting for Application/$APP_NAME to be generated"
ok=0
for _ in $(seq 1 30); do
  kubectl get application "$APP_NAME" -n "$ARGOCD_NS" >/dev/null 2>&1 && { ok=1; break; }
  sleep 4
done
[ "$ok" = 1 ] || { echo "    FAIL: ApplicationSet never generated Application/$APP_NAME."; exit 1; }
echo "    Application/$APP_NAME generated by the ApplicationSet."

echo "==> [3-assert] Application/$APP_NAME must reach Synced + Healthy"
t=0 sync="" health=""
while [ "$t" -lt 300 ]; do
  sync="$(kubectl get application "$APP_NAME" -n "$ARGOCD_NS" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kubectl get application "$APP_NAME" -n "$ARGOCD_NS" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  [ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] && break
  sleep 5; t=$((t + 5))
done
[ "$sync" = "Synced" ] && [ "$health" = "Healthy" ] || {
  echo "    FAIL: Application/$APP_NAME did not reach Synced+Healthy (sync=$sync health=$health)."; exit 1; }
echo "    OK: Application/$APP_NAME is Synced + Healthy."

# ── 3b. A5 ORDERING FIX (issue #177 / A4 residual): the generated Application ──
# carries the sync-wave that orders it AFTER the platform add-ons (argo-rollouts
# wave 0 lands the Rollout CRD) AND a retry block so a Rollout-shaped workload that
# races ahead of the CRD converges instead of stranding. The sample workload is a
# plain Deployment, so it does not itself hit the Rollout race — this asserts the
# ORDERING SHAPE is wired onto every generated workload Application (the closure of
# the residual window A4 flagged; the CRD-first delivery itself is proven by
# scripts/e2e/assert-argo-rollouts.sh, wave 0, in the same lane).
echo "==> [3b-assert] generated Application carries the A4 ordering shape (sync-wave + retry)"
WAVE="$(kubectl get application "$APP_NAME" -n "$ARGOCD_NS" -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-wave}' 2>/dev/null || true)"
RETRY_LIMIT="$(kubectl get application "$APP_NAME" -n "$ARGOCD_NS" -o jsonpath='{.spec.syncPolicy.retry.limit}' 2>/dev/null || true)"
[ "$WAVE" = "3" ] || { echo "    FAIL: generated Application sync-wave='$WAVE' (want 3 — A4 ordering after wave-0 add-ons)."; exit 1; }
[ -n "$RETRY_LIMIT" ] && [ "$RETRY_LIMIT" != "0" ] || { echo "    FAIL: generated Application has no syncPolicy.retry (A4 convergence backstop missing)."; exit 1; }
echo "    OK: sync-wave=$WAVE, retry.limit=$RETRY_LIMIT (Rollout-CRD ordering + convergence backstop wired)."

# ── 4. positive: digest-pinned workload pod is admitted + running ────────────
echo "==> [4-assert] digest-pinned workload Deployment is available (admitted)"
kubectl rollout status deploy/sample-app -n "$APP_NS" --timeout=120s
echo "    OK: sample-app Deployment available (digest-pinned pod admitted by require-digest)."

# ── 5. assert the per-workload / per-account injections landed ───────────────
echo "==> [5-assert] always-on commonAnnotations injected onto the workload"
REGION_ANNO="$(kubectl get deploy/sample-app -n "$APP_NS" -o jsonpath='{.metadata.annotations.aegis\.binhsu\.org/region}')"
ECR_ANNO="$(kubectl get deploy/sample-app -n "$APP_NS" -o jsonpath='{.metadata.annotations.aegis\.binhsu\.org/ecr-repository}')"
EXPECT_ECR="000000000000.dkr.ecr.eu-central-1.amazonaws.com/aegis-sample"
[ "$REGION_ANNO" = "$REGION" ] || { echo "    FAIL: region annotation '$REGION_ANNO' != '$REGION'."; exit 1; }
[ "$ECR_ANNO" = "$EXPECT_ECR" ] || { echo "    FAIL: ecr-repository annotation '$ECR_ANNO' != '$EXPECT_ECR'."; exit 1; }
echo "    OK: region=$REGION_ANNO ecr-repository=$ECR_ANNO"

echo "==> [5-assert] conditional model-store injection FIRED (engine_irsa gate)"
BUCKET="$(kubectl get configmap aegis-sample-model-store -n "$APP_NS" -o jsonpath='{.data.bucket}')"
[ "$BUCKET" = "$MODEL_BUCKET" ] || {
  echo "    FAIL: model-store bucket '$BUCKET' != injected '$MODEL_BUCKET' (templatePatch did not fire)."; exit 1; }
echo "    OK: aegis-sample-model-store data.bucket=$BUCKET (injected, not the PLACEHOLDER)."

# ── 6. negative: a tag-only VARIANT of the workload is DENIED at admission ────
# Reuses B1's require-digest gate, but against a real Deployment. Kyverno autogen
# extends the Pod-matching policy to Pod controllers, so the tag-only Deployment
# create is rejected synchronously. Fallback (if autogen ever differs): the apply
# succeeds but pods never create — assert the ReplicaSet FailedCreate cites the
# policy — so the negative holds either way.
echo "==> [6-assert] NEGATIVE: tag-only workload variant must be DENIED"
TAGONLY="$(mktemp)"
cat >"$TAGONLY" <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sample-app-tagonly
  namespace: $APP_NS
  labels:
    aegis.binhsu.org/test: require-digest-negative-workload
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: sample-app-tagonly
  template:
    metadata:
      labels:
        app.kubernetes.io/name: sample-app-tagonly
    spec:
      containers:
        - name: tag-only
          image: busybox:1.37
          command: ["sh", "-c", "sleep 3600"]
YAML
if kubectl apply -f "$TAGONLY" 2>/tmp/b2-tagonly.err; then
  # Autogen did not reject at the Deployment; fall back to the pod-create path.
  echo "    Deployment admitted — checking pods are blocked at creation (autogen fallback)"
  blocked=0
  for _ in $(seq 1 15); do
    if kubectl -n "$APP_NS" get events --field-selector reason=FailedCreate 2>/dev/null \
        | grep -qi 'require-image-digest\|sha256 digest'; then blocked=1; break; fi
    if kubectl -n "$APP_NS" describe rs -l app.kubernetes.io/name=sample-app-tagonly 2>/dev/null \
        | grep -qi 'require-image-digest\|sha256 digest'; then blocked=1; break; fi
    sleep 4
  done
  kubectl delete -f "$TAGONLY" --ignore-not-found >/dev/null 2>&1 || true
  [ "$blocked" = 1 ] || { echo "    FAIL: tag-only workload pods were NOT blocked by require-digest."; exit 1; }
  echo "    OK: tag-only workload pods rejected at creation by require-image-digest."
else
  # Rejected synchronously at Deployment admission (Kyverno autogen) — the norm.
  if ! grep -qi 'require-image-digest\|sha256 digest\|require-digest-pinned-image' /tmp/b2-tagonly.err; then
    echo "    FAIL: tag-only workload rejected, but not by require-image-digest. Error was:"
    cat /tmp/b2-tagonly.err
    exit 1
  fi
  echo "    OK: tag-only workload Deployment rejected at admission by require-image-digest:"
  grep -i 'sha256 digest\|require-image-digest' /tmp/b2-tagonly.err | head -2 | sed 's/^/      /'
fi

echo ""
echo "==> B2 WORKLOAD ONBOARDING PASSED (zero AWS spend):"
echo "    [3] ApplicationSet List-generator fan-out → Application/$APP_NAME Synced + Healthy"
echo "    [3b] generated Application carries the A5/A4 ordering shape (sync-wave 3 + retry)"
echo "    [4] digest-pinned workload admitted + running (local registry:2 image source)"
echo "    [5] commonAnnotations (region + ecr-repository) + model-store injection landed"
echo "    [6] tag-only workload variant DENIED by require-image-digest"
