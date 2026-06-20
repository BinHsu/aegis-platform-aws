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
# Usage:
#   PROFILE=aegis-staging-admin \
#   PRIMARY_CTX=eu-central-1 SECONDARY_CTX=eu-west-1 \
#   PLATFORM_TF_DIR=/path/to/terraform/envs/platform \
#   PRIMARY_REGIONAL_TF_DIR=/path/to/terraform/envs/regional-eu-central-1 \
#   SECONDARY_REGIONAL_TF_DIR=/path/to/terraform/envs/regional-eu-west-1 \
#   VERIFY_IMAGE=<registry>/aegis-verify:latest \
#   PROTO_CONFIGMAP=aegis-proto \
#   PCM_CONFIGMAP=aegis-pcm-fixture \
#   HARNESS_DIR=/path/to/scripts/verify \
#   ./scripts/verify/run-incluster-verify.sh
#
# Override any derived value by setting it explicitly before running.
set -uo pipefail

PROFILE="${PROFILE:-aegis-staging-admin}"
PRIMARY_CTX="${PRIMARY_CTX:-eu-central-1}"
SECONDARY_CTX="${SECONDARY_CTX:-eu-west-1}"
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
VERIFY_IMAGE="${VERIFY_IMAGE:?set VERIFY_IMAGE to the verifier container image reference}"
PROTO_CONFIGMAP="${PROTO_CONFIGMAP:-aegis-proto}"
PCM_CONFIGMAP="${PCM_CONFIGMAP:-aegis-pcm-fixture}"
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

# ── Per-region verification function ─────────────────────────────────────────
verify_region() {
  local ctx="$1" regional_tf_dir="${2:-}"
  local region="$ctx"
  local rc=0

  log "=== verifying region: $region (ctx: $ctx) ==="

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
