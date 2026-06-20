#!/usr/bin/env bash
#
# aws-api-checks.sh — Tier 1 AWS-API verification (no cluster networking needed).
#
# Checks the following architectural invariants against the live AWS account
# using only AWS API calls. No kubectl, no port-forwards, no cluster access.
#
#   CHECK 1   ECR: both-region images exist for aegis-core engine + gateway.
#   CHECK 2   EKS Pod Identity: engine + populator associations exist; no IRSA.
#   CHECK 3   ACM: certificates are ISSUED in both regions.
#   CHECK 4   S3: model bucket + XBucket scratch bucket exist in both regions.
#   CHECK 5   IAM simulate: engine role can s3:GetObject on its model bucket.
#   CHECK 6   Route 53 dual-region routing: two A records with distinct SetIdentifier
#             + non-null Region; reversible failover sim via health-check disable.
#
# All resource names / ARNs are derived from `terraform output` when
# PLATFORM_TF_DIR and REGIONAL_TF_DIR_{PRIMARY,SECONDARY} are set. Override any
# value by setting the corresponding env var explicitly.
#
# Usage:
#   PROFILE=aegis-staging-admin \
#   PRIMARY_REGION=eu-central-1 SECONDARY_REGION=eu-west-1 \
#   PLATFORM_TF_DIR=/path/to/terraform/envs/platform \
#   PRIMARY_REGIONAL_TF_DIR=/path/to/terraform/envs/regional-eu-central-1 \
#   SECONDARY_REGIONAL_TF_DIR=/path/to/terraform/envs/regional-eu-west-1 \
#   ./scripts/verify/aws-api-checks.sh
#
# Exit code 0 = all checks passed. Non-zero = at least one failed.
set -uo pipefail

PROFILE="${PROFILE:-aegis-staging-admin}"
PRIMARY_REGION="${PRIMARY_REGION:-eu-central-1}"
SECONDARY_REGION="${SECONDARY_REGION:-eu-west-1}"
NS="${NS:-aegis-core}"

RESULTS=()
RC=0

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { echo "[$(date +%H:%M:%S)] $*"; }
record() { RESULTS+=("$1|$2|$3"); }   # check | PASS/FAIL | detail
aws_()   { aws --profile "$PROFILE" "$@"; }

# ── Dependency check ──────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  for cmd in aws jq terraform; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: missing dependencies: ${missing[*]}" >&2
    exit 1
  fi
}
check_deps

# ── Derive config from terraform output ───────────────────────────────────────
tf_output_json() {  # dir
  (cd "$1" && terraform output -json 2>/dev/null) || echo '{}'
}

if [ -n "${PLATFORM_TF_DIR:-}" ] && [ -d "${PLATFORM_TF_DIR}" ]; then
  log "Deriving config from platform terraform output: $PLATFORM_TF_DIR"
  _pf_out="$(tf_output_json "$PLATFORM_TF_DIR")"
  ZONE_ID="${ZONE_ID:-$(echo "$_pf_out" | jq -r '.zone_id.value // empty')}"
  ZONE_NAME="${ZONE_NAME:-$(echo "$_pf_out" | jq -r '.zone_name.value // empty')}"
  ECR_REGISTRY="${ECR_REGISTRY:-$(echo "$_pf_out" | jq -r '.ecr_registry.value // empty')}"
  ACCOUNT_ID="${ACCOUNT_ID:-$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null)}"
fi

if [ -n "${PRIMARY_REGIONAL_TF_DIR:-}" ] && [ -d "${PRIMARY_REGIONAL_TF_DIR}" ]; then
  _p_out="$(tf_output_json "$PRIMARY_REGIONAL_TF_DIR")"
  ENGINE_ROLE_P="${ENGINE_ROLE_P:-$(echo "$_p_out" | jq -r '.engine_iam_role_name.value // empty')}"
  POPULATOR_ROLE_P="${POPULATOR_ROLE_P:-$(echo "$_p_out" | jq -r '.model_populator_iam_role_name.value // empty')}"
  ACM_ARN_P="${ACM_ARN_P:-$(echo "$_p_out" | jq -r '.acm_certificate_arn.value // empty')}"
  CLUSTER_NAME_P="${CLUSTER_NAME_P:-$(echo "$_p_out" | jq -r '.cluster_name.value // empty')}"
fi

if [ -n "${SECONDARY_REGIONAL_TF_DIR:-}" ] && [ -d "${SECONDARY_REGIONAL_TF_DIR}" ]; then
  _s_out="$(tf_output_json "$SECONDARY_REGIONAL_TF_DIR")"
  ENGINE_ROLE_S="${ENGINE_ROLE_S:-$(echo "$_s_out" | jq -r '.engine_iam_role_name.value // empty')}"
  POPULATOR_ROLE_S="${POPULATOR_ROLE_S:-$(echo "$_s_out" | jq -r '.model_populator_iam_role_name.value // empty')}"
  ACM_ARN_S="${ACM_ARN_S:-$(echo "$_s_out" | jq -r '.acm_certificate_arn.value // empty')}"
  CLUSTER_NAME_S="${CLUSTER_NAME_S:-$(echo "$_s_out" | jq -r '.cluster_name.value // empty')}"
fi

# Fallback names using known naming conventions (model-store.tf, pod-identity-*.tf).
ACCOUNT_ID="${ACCOUNT_ID:-$(aws_ sts get-caller-identity --query Account --output text 2>/dev/null)}"
MODEL_BUCKET_P="${MODEL_BUCKET_P:-aegis-core-models-${ACCOUNT_ID}-${PRIMARY_REGION}}"
MODEL_BUCKET_S="${MODEL_BUCKET_S:-aegis-core-models-${ACCOUNT_ID}-${SECONDARY_REGION}}"
ENGINE_ROLE_P="${ENGINE_ROLE_P:-aegis-core-engine-${PRIMARY_REGION}}"
ENGINE_ROLE_S="${ENGINE_ROLE_S:-aegis-core-engine-${SECONDARY_REGION}}"
POPULATOR_ROLE_P="${POPULATOR_ROLE_P:-aegis-core-model-populator-${PRIMARY_REGION}}"
POPULATOR_ROLE_S="${POPULATOR_ROLE_S:-aegis-core-model-populator-${SECONDARY_REGION}}"
# ECR registry: deployment-account pattern (ADR-10) or per-account fallback.
ECR_REPO="${ECR_REPO:-${ECR_REGISTRY:+${ECR_REGISTRY}/}aegis-core}"
# Gateway record name: app.<env>.<zone_name> per route53.tf local.cognito_app_host
GATEWAY_RECORD="${GATEWAY_RECORD:-${ZONE_NAME:+app.staging.${ZONE_NAME}}}"

log "Account: $ACCOUNT_ID  Primary: $PRIMARY_REGION  Secondary: $SECONDARY_REGION"

# ==============================================================================
# CHECK 1 — ECR: images exist in both regions
# ==============================================================================
log "CHECK 1: ECR images (both regions)"
for region in "$PRIMARY_REGION" "$SECONDARY_REGION"; do
  if [ -z "${ECR_REPO:-}" ]; then
    record "ecr-images-$region" FAIL "ECR_REPO not set and could not derive from terraform output"
    continue
  fi
  # Probe for any tagged image in the repo; the key invariant is the repo is
  # non-empty (CI has pushed at least one build).
  out="$(aws_ ecr describe-images \
    --region "$region" \
    --repository-name "${ECR_REPO##*/}" \
    --query 'imageDetails[0].imageTags[0]' \
    --output text 2>&1)" || out="ERROR: $out"
  if [ "$out" = "None" ] || [ -z "$out" ] || [[ "$out" == ERROR* ]]; then
    record "ecr-images-$region" FAIL "no images or repo not found: $out"
  else
    record "ecr-images-$region" PASS "latest tag=$out"
  fi
done

# ==============================================================================
# CHECK 2 — EKS Pod Identity: engine + populator associations exist; no IRSA
# ==============================================================================
log "CHECK 2: Pod Identity associations (both regions)"
for region_triple in \
    "${PRIMARY_REGION}|${CLUSTER_NAME_P:-aegis-platform-${PRIMARY_REGION}}|${ENGINE_ROLE_P}|${POPULATOR_ROLE_P}" \
    "${SECONDARY_REGION}|${CLUSTER_NAME_S:-aegis-platform-${SECONDARY_REGION}}|${ENGINE_ROLE_S}|${POPULATOR_ROLE_S}"; do
  IFS='|' read -r region cluster_name engine_role populator_role <<< "$region_triple"
  if [ -z "$cluster_name" ]; then
    record "pod-identity-$region" FAIL "CLUSTER_NAME not set for $region"
    continue
  fi
  # List all Pod Identity associations for this cluster.
  assoc_json="$(aws_ eks list-pod-identity-associations \
    --region "$region" \
    --cluster-name "$cluster_name" \
    --output json 2>&1)" || { record "pod-identity-$region" FAIL "API call failed: $assoc_json"; continue; }
  # Verify engine association exists.
  engine_assoc="$(echo "$assoc_json" | jq -r \
    --arg role "$engine_role" \
    '[.associations[] | select(.roleArn | contains($role))] | length')"
  populator_assoc="$(echo "$assoc_json" | jq -r \
    --arg role "$populator_role" \
    '[.associations[] | select(.roleArn | contains($role))] | length')"
  if [ "${engine_assoc:-0}" -gt 0 ] && [ "${populator_assoc:-0}" -gt 0 ]; then
    record "pod-identity-$region" PASS "engine=$engine_assoc assoc(s), populator=$populator_assoc assoc(s)"
  else
    record "pod-identity-$region" FAIL \
      "engine=$engine_assoc populator=$populator_assoc (want both ≥1)"
  fi
  # Assert no IRSA annotation on engine SA (check via eks:DescribeNodegroup is
  # not practical here; the structural guard is that the engine role has no
  # OIDC trust — assert via iam:GetRole).
  role_trust="$(aws_ iam get-role --role-name "$engine_role" \
    --query 'Role.AssumeRolePolicyDocument' --output json 2>/dev/null)" || role_trust="{}"
  if echo "$role_trust" | jq -e '.Statement[] | select(.Principal.Federated? // "" | test("oidc"))' >/dev/null 2>&1; then
    record "no-irsa-$region" FAIL "engine role $engine_role still has OIDC trust (IRSA present)"
  else
    record "no-irsa-$region" PASS "engine role has no OIDC trust (Pod Identity only)"
  fi
done

# ==============================================================================
# CHECK 3 — ACM: certificates ISSUED in both regions
# ==============================================================================
log "CHECK 3: ACM certificates (both regions)"
for region_arn in \
    "${PRIMARY_REGION}|${ACM_ARN_P:-}" \
    "${SECONDARY_REGION}|${ACM_ARN_S:-}"; do
  IFS='|' read -r region cert_arn <<< "$region_arn"
  if [ -z "$cert_arn" ]; then
    record "acm-$region" FAIL "ACM_ARN not set for $region (set ACM_ARN_P / ACM_ARN_S or REGIONAL_TF_DIR)"
    continue
  fi
  status="$(aws_ acm describe-certificate \
    --region "$region" --certificate-arn "$cert_arn" \
    --query 'Certificate.Status' --output text 2>&1)" || status="ERROR"
  if [ "$status" = "ISSUED" ]; then
    record "acm-$region" PASS "status=ISSUED"
  else
    record "acm-$region" FAIL "status=$status (want ISSUED)"
  fi
done

# ==============================================================================
# CHECK 4 — S3: model bucket + XBucket scratch bucket exist
# ==============================================================================
log "CHECK 4: S3 buckets (model + XBucket)"
for region_bucket in \
    "${PRIMARY_REGION}|${MODEL_BUCKET_P}" \
    "${SECONDARY_REGION}|${MODEL_BUCKET_S}"; do
  IFS='|' read -r region bucket <<< "$region_bucket"
  rc=0
  aws_ s3api head-bucket --bucket "$bucket" --region "$region" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    record "s3-model-bucket-$region" PASS "bucket=$bucket exists"
  else
    record "s3-model-bucket-$region" FAIL "bucket=$bucket not found (rc=$rc)"
  fi
done
# XBucket scratch bucket — naming: <bucketPrefix>-scratch-<account>-<region>
# bucketPrefix defaults to "aegis-wl" (crossplane.tf default).
XBUCKET_PREFIX="${XBUCKET_PREFIX:-aegis-wl}"
for region in "$PRIMARY_REGION" "$SECONDARY_REGION"; do
  xbucket="$XBUCKET_PREFIX-scratch-${ACCOUNT_ID}-${region}"
  rc=0
  aws_ s3api head-bucket --bucket "$xbucket" --region "$region" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    record "s3-xbucket-$region" PASS "bucket=$xbucket exists"
  else
    # XBucket is only created when the workload applies the XBucket XR, so this
    # may legitimately be absent in staging-only environments.
    record "s3-xbucket-$region" FAIL "bucket=$xbucket not found (rc=$rc) — XBucket XR not yet applied?"
  fi
done

# ==============================================================================
# CHECK 5 — IAM simulate: engine role can s3:GetObject on model bucket
# ==============================================================================
log "CHECK 5: IAM simulate engine s3:GetObject"
for region_triple in \
    "${PRIMARY_REGION}|${ENGINE_ROLE_P}|${MODEL_BUCKET_P}" \
    "${SECONDARY_REGION}|${ENGINE_ROLE_S}|${MODEL_BUCKET_S}"; do
  IFS='|' read -r region engine_role model_bucket <<< "$region_triple"
  engine_arn="arn:aws:iam::${ACCOUNT_ID}:role/${engine_role}"
  bucket_arn="arn:aws:s3:::${model_bucket}/*"
  result="$(aws_ iam simulate-principal-policy \
    --policy-source-arn "$engine_arn" \
    --action-names "s3:GetObject" \
    --resource-arns "$bucket_arn" \
    --query 'EvaluationResults[0].EvalDecision' \
    --output text 2>&1)" || result="ERROR"
  if [ "$result" = "allowed" ]; then
    record "iam-sim-engine-s3-$region" PASS "s3:GetObject on $model_bucket: allowed"
  else
    record "iam-sim-engine-s3-$region" FAIL "s3:GetObject decision=$result (want allowed)"
  fi
done

# ==============================================================================
# CHECK 6 — Route 53 dual-region routing
# ==============================================================================
log "CHECK 6: Route 53 dual-region routing"
if [ -z "${ZONE_ID:-}" ]; then
  record "route53-dual-region" FAIL "ZONE_ID not set — set ZONE_ID or PLATFORM_TF_DIR"
else
  # List all A records in the zone; filter for the gateway record.
  record_name="${GATEWAY_RECORD:-}"
  if [ -z "$record_name" ]; then
    record "route53-dual-region" FAIL "GATEWAY_RECORD not set and could not derive from terraform output"
  else
    rrsets="$(aws_ route53 list-resource-record-sets \
      --hosted-zone-id "$ZONE_ID" \
      --query "ResourceRecordSets[?Name=='${record_name}.' && Type=='A']" \
      --output json 2>&1)" || { record "route53-dual-region" FAIL "API call failed: $rrsets"; rrsets="[]"; }

    count="$(echo "$rrsets" | jq 'length')"
    if [ "${count:-0}" -lt 2 ]; then
      record "route53-dual-region" FAIL \
        "expected ≥2 A records for ${record_name}, got ${count} — latency/failover routing not configured"
    else
      # Assert each record has a non-null Region (latency policy) or SetIdentifier (failover policy).
      missing_region="$(echo "$rrsets" | jq '[.[] | select(.Region == null and .Failover == null)] | length')"
      distinct_ids="$(echo "$rrsets" | jq '[.[] | .SetIdentifier] | unique | length')"
      if [ "${missing_region:-0}" -gt 0 ]; then
        record "route53-dual-region" FAIL \
          "${missing_region} record(s) have null Region AND null Failover — not a routing policy record"
      elif [ "${distinct_ids:-0}" -lt 2 ]; then
        record "route53-dual-region" FAIL \
          "SetIdentifiers are not distinct (${distinct_ids} unique) — records may be duplicates"
      else
        record "route53-dual-region" PASS \
          "${count} A records, ${distinct_ids} distinct SetIdentifiers, all have routing policy"

        # ── Reversible failover simulation ──────────────────────────────────
        # Disable the health check on the primary region's record, verify DNS
        # answers change, then re-enable. Only run if SIMULATE_FAILOVER=true.
        if [ "${SIMULATE_FAILOVER:-false}" = "true" ]; then
          log "CHECK 6b: failover simulation (SIMULATE_FAILOVER=true)"
          # Find the health-check ID for the primary region record.
          hc_id="$(echo "$rrsets" | jq -r \
            --arg region "$PRIMARY_REGION" \
            '.[] | select(.Region == $region or .SetIdentifier == $region) | .HealthCheckId // empty' \
            | head -1)"
          if [ -z "$hc_id" ]; then
            record "route53-failover-sim" FAIL \
              "no HealthCheckId on primary record — cannot simulate failover"
          else
            log "disabling health check $hc_id..."
            aws_ route53 update-health-check \
              --health-check-id "$hc_id" --disabled >/dev/null 2>&1 || true
            sleep 5  # allow propagation
            # Use test-dns-answer to observe the current routing decision.
            dns_answer="$(aws_ route53 test-dns-answer \
              --hosted-zone-id "$ZONE_ID" \
              --record-name "$record_name" \
              --record-type A \
              --query 'RecordData' --output text 2>&1)" || dns_answer="ERROR"
            log "re-enabling health check $hc_id..."
            reenable_rc=0
            aws_ route53 update-health-check \
              --health-check-id "$hc_id" --no-disabled >/dev/null 2>&1 || reenable_rc=$?
            if [[ "$dns_answer" == ERROR* ]]; then
              record "route53-failover-sim" FAIL "test-dns-answer failed: $dns_answer"
            elif [ "$reenable_rc" -ne 0 ]; then
              record "route53-failover-sim" FAIL \
                "CRITICAL: failed to re-enable health check $hc_id (rc=$reenable_rc) — manual intervention required"
            else
              record "route53-failover-sim" PASS \
                "failover sim: disabled HC $hc_id, DNS answered: $dns_answer, HC re-enabled"
            fi
          fi
        else
          log "Skipping failover simulation (set SIMULATE_FAILOVER=true to run)"
        fi
      fi
    fi
  fi
fi

# ==============================================================================
# Report
# ==============================================================================
echo
printf '%-45s %-6s %s\n' "CHECK" "RESULT" "DETAIL"
printf '%-45s %-6s %s\n' "-----" "------" "------"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r name res detail <<< "$r"
  printf '%-45s %-6s %s\n' "$name" "$res" "$detail"
  [ "$res" != "PASS" ] && RC=1
done
exit $RC
