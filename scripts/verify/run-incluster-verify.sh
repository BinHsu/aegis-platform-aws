#!/usr/bin/env bash
#
# run-incluster-verify.sh — Tier 2 in-cluster verifier driver.
#
# Derives cluster config from `terraform output`, applies the verifier Job into
# each region's cluster, waits for completion, fetches the logs, and deletes the
# Job. Exits non-zero if any region fails.
#
# Requirements: kubectl (contexts configured), aws CLI, terraform, envsubst, jq.
#
# This is the DEFAULT verification path for unattended runs (#145): it runs
# grpcurl/BVA/PKCE from a Job INSIDE the cluster over service DNS — no laptop
# kubectl port-forward and no `kill`/`pkill` (which the port-forward path needs
# and which the kill-guard hook blocks headless). The laptop port-forward path
# (ws4-app-functional-e2e.sh) is now the explicitly-requested interactive
# fallback, not the default.
#
# The verifier image is PRE-BUILT and published by .github/workflows/
# verifier-image.yml to ghcr.io/<owner>/aegis-verify — VERIFY_IMAGE defaults to
# it, so an unattended run never builds an image ad hoc.
#
# Usage:
#   PROFILE=aegis-staging-admin \
#   PRIMARY_CTX=eu-central-1 SECONDARY_CTX=eu-west-1 \
#   PLATFORM_TF_DIR=/path/to/terraform/envs/platform \
#   PRIMARY_REGIONAL_TF_DIR=/path/to/terraform/envs/regional-eu-central-1 \
#   SECONDARY_REGIONAL_TF_DIR=/path/to/terraform/envs/regional-eu-west-1 \
#   [VERIFY_IMAGE=ghcr.io/binhsu/aegis-verify:latest] \
#   [PROTO=/path/to/aegis.proto PCM_FIXTURE=/tmp/x.pcm] \
#   [PROTO_CONFIGMAP=aegis-proto PCM_CONFIGMAP=aegis-pcm-fixture] \
#   HARNESS_DIR=/path/to/scripts/verify \
#   ./scripts/verify/run-incluster-verify.sh
#
# If PROTO / PCM_FIXTURE are set, the driver seeds the proto + PCM ConfigMaps into
# the aegis-core namespace (idempotent) so the Job is always ready — #145 point 2.
# Override any derived value by setting it explicitly before running.
set -uo pipefail

PROFILE="${PROFILE:-aegis-staging-admin}"
PRIMARY_CTX="${PRIMARY_CTX:-eu-central-1}"
SECONDARY_CTX="${SECONDARY_CTX:-eu-west-1}"
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# Default to the published verifier image (#145). Override for a private registry
# (e.g. the deployment ECR) or to pin a digest once require-image-digest enforces.
VERIFY_IMAGE="${VERIFY_IMAGE:-ghcr.io/binhsu/aegis-verify:latest}"
PROTO_CONFIGMAP="${PROTO_CONFIGMAP:-aegis-proto}"
PCM_CONFIGMAP="${PCM_CONFIGMAP:-aegis-pcm-fixture}"
# Optional local sources for seeding the ConfigMaps if they are not already in
# the namespace. Leave unset if bring-up already created them.
PROTO="${PROTO:-}"
PCM_FIXTURE="${PCM_FIXTURE:-}"
JOB_WAIT_TIMEOUT="${JOB_WAIT_TIMEOUT:-300s}"
NS="${NS:-aegis-core}"

log() { echo "[$(date +%H:%M:%S)] $*"; }
OVERALL_RC=0

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in kubectl aws terraform envsubst jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: missing dependencies: ${missing[*]}" >&2
    exit 1
  fi
}
check_deps

# ── Derive config from terraform output ───────────────────────────────────────
derive_from_tf() {
  local tf_dir="$1"
  if [ ! -d "$tf_dir" ]; then
    echo "ERROR: terraform dir not found: $tf_dir" >&2
    return 1
  fi
  (cd "$tf_dir" && terraform output -json 2>/dev/null)
}

log "Deriving Cognito config from platform terraform output"
if [ -n "${PLATFORM_TF_DIR:-}" ]; then
  _platform_out="$(derive_from_tf "$PLATFORM_TF_DIR")"
  _issuer="$(echo "$_platform_out" | jq -r '.cognito_issuer.value // empty')"
  POOL="${POOL:-${_issuer##*/}}"
  CLIENT_ID="${CLIENT_ID:-$(echo "$_platform_out" | jq -r '.cognito_app_client_id.value // empty')}"
  _hosted_ui="$(echo "$_platform_out" | jq -r '.cognito_hosted_ui_domain.value // empty')"
  COGNITO_DOMAIN="${COGNITO_DOMAIN:-https://$_hosted_ui}"
  COGNITO_REGION="${COGNITO_REGION:-$(echo "$_platform_out" | jq -r '.aws_region.value // "eu-central-1"')}"
fi

# Ensure required vars are present.
: "${POOL:?set POOL or PLATFORM_TF_DIR}"
: "${CLIENT_ID:?set CLIENT_ID or PLATFORM_TF_DIR}"
: "${COGNITO_DOMAIN:?set COGNITO_DOMAIN or PLATFORM_TF_DIR}"
: "${COGNITO_REGION:=${POOL%%_*}}"  # fallback: pool-id region prefix

# ── Seed proto + PCM ConfigMaps (idempotent) ─────────────────────────────────
# #145 point 2: the Job is always ready because bring-up seeds these ConfigMaps.
# If bring-up already created them (or PROTO/PCM_FIXTURE are unset), this is a
# no-op — we never overwrite an existing ConfigMap, only create a missing one.
ensure_configmaps() {
  local ctx="$1"
  # Ensure the target namespace exists (bring-up normally creates it; be safe).
  kubectl --context "$ctx" get namespace "$NS" >/dev/null 2>&1 || {
    log "namespace $NS absent on $ctx — creating"
    kubectl --context "$ctx" create namespace "$NS" >/dev/null 2>&1 || true
  }

  if ! kubectl --context "$ctx" -n "$NS" get configmap "$PROTO_CONFIGMAP" >/dev/null 2>&1; then
    if [ -n "$PROTO" ] && [ -f "$PROTO" ]; then
      log "seeding configmap/$PROTO_CONFIGMAP on $ctx from $PROTO"
      kubectl --context "$ctx" -n "$NS" create configmap "$PROTO_CONFIGMAP" \
        --from-file="aegis.proto=$PROTO" >/dev/null
    else
      log "WARN: configmap/$PROTO_CONFIGMAP missing on $ctx and PROTO not set — Job will fail"
    fi
  fi

  if ! kubectl --context "$ctx" -n "$NS" get configmap "$PCM_CONFIGMAP" >/dev/null 2>&1; then
    if [ -n "$PCM_FIXTURE" ] && [ -f "$PCM_FIXTURE" ]; then
      log "seeding configmap/$PCM_CONFIGMAP on $ctx from $PCM_FIXTURE"
      kubectl --context "$ctx" -n "$NS" create configmap "$PCM_CONFIGMAP" \
        --from-file="fixture.pcm=$PCM_FIXTURE" >/dev/null
    else
      log "WARN: configmap/$PCM_CONFIGMAP missing on $ctx and PCM_FIXTURE not set — Job will fail"
    fi
  fi
}

# ── Per-region verification function ─────────────────────────────────────────
verify_region() {
  local ctx="$1" regional_tf_dir="${2:-}"
  local region="$ctx"
  local rc=0

  log "=== verifying region: $region (ctx: $ctx) ==="

  ensure_configmaps "$ctx"

  # Derive model bucket name from regional terraform output if dir is set.
  local model_bucket="" aws_region="$region"
  if [ -n "$regional_tf_dir" ] && [ -d "$regional_tf_dir" ]; then
    _regional_out="$(derive_from_tf "$regional_tf_dir" 2>/dev/null || echo '{}')"
    model_bucket="$(echo "$_regional_out" | jq -r '.model_bucket_name.value // empty' 2>/dev/null || true)"
    # model_bucket_name is a local in the module — expose via a future output if needed.
    # Fallback: construct from the known naming convention.
    if [ -z "$model_bucket" ]; then
      _account_id="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null || true)"
      model_bucket="${model_bucket:-aegis-core-models-${_account_id:-unknown}-${region}}"
    fi
  fi

  # Generate a unique job name.
  local job_suffix
  job_suffix="$(date +%s)-${region//[^a-z0-9]/-}"
  local job_name="aegis-verify-${job_suffix}"

  # Substitute template variables and apply the Job.
  export VERIFY_IMAGE PROTO_CONFIGMAP PCM_CONFIGMAP COGNITO_DOMAIN CLIENT_ID POOL \
         COGNITO_REGION MODEL_BUCKET="${model_bucket}" AWS_REGION="${aws_region}" \
         JOB_SUFFIX="$job_suffix"

  local job_yaml
  job_yaml="$(envsubst < "${HARNESS_DIR}/k8s/verifier-job.yaml")"

  # Inject the resolved job name (envsubst already expanded JOB_SUFFIX above).
  log "applying job $job_name to context $ctx"
  echo "$job_yaml" | kubectl --context "$ctx" apply -f - >/dev/null

  # Wait for the Job to complete or fail.
  log "waiting up to $JOB_WAIT_TIMEOUT for job/$job_name..."
  if kubectl --context "$ctx" -n "$NS" wait \
       "job/${job_name}" \
       --for=condition=complete \
       --timeout="$JOB_WAIT_TIMEOUT" >/dev/null 2>&1; then
    log "job/$job_name: COMPLETE"
  else
    log "job/$job_name: did not complete within timeout — fetching logs and failing"
    rc=1
  fi

  # Fetch logs regardless of status.
  log "--- logs from job/$job_name ($ctx) ---"
  kubectl --context "$ctx" -n "$NS" logs "job/${job_name}" 2>/dev/null || true
  log "--- end logs ---"

  # Delete the Job to avoid orphans.
  kubectl --context "$ctx" -n "$NS" delete "job/${job_name}" --ignore-not-found >/dev/null 2>&1 || true

  return $rc
}

# ── Run both regions ─────────────────────────────────────────────────────────
verify_region "$PRIMARY_CTX"   "${PRIMARY_REGIONAL_TF_DIR:-}" || OVERALL_RC=1
verify_region "$SECONDARY_CTX" "${SECONDARY_REGIONAL_TF_DIR:-}" || OVERALL_RC=1

if [ "$OVERALL_RC" -eq 0 ]; then
  log "OVERALL: PASS — both regions verified"
else
  log "OVERALL: FAIL — see logs above"
fi
exit $OVERALL_RC
