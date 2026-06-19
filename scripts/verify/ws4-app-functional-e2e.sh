#!/usr/bin/env bash
#
# ws4-app-functional-e2e.sh — WS4 §7D application-functional E2E verification harness.
#
# Runs three checks against a live dual-region aegis-core deployment and prints a
# PASS/FAIL table. It proves the application *works*, not just that infrastructure
# applied:
#
#   TEST 1  Real transcription via the internal Engine (native gRPC, no auth).
#           Streams a PCM fixture into aegis.v1.Engine/StreamTranscribe and checks
#           the returned TranscriptSegment.text. Proves model -> text on the real
#           cluster (Pod-Identity-fetched whisper-tiny-en).
#
#   TEST 2  OIDC boundary-value analysis (BVA) at the public Gateway, over
#           improbable-eng grpc-web. Negative faces (no-token / garbage / malformed
#           / tampered-signature) must all return grpc-status 16 (Unauthenticated).
#           The valid face must NOT return 16 (it reaches the handler).
#
#   TEST 3  Valid PKCE id_token from the Cognito Hosted-UI authorization-code flow,
#           used as TEST 2's valid face. Confirms the pre-token Lambda injected
#           custom:tenant_id.
#
# The Gateway speaks improbable-eng grpc-web (content-type application/grpc-web+proto),
# NOT native gRPC and NOT Connect — grpcurl and plain JSON both 404. This harness
# hand-frames grpc-web requests and reads the grpc-status trailer (helper: grpcweb.py).
#
# Requirements: kubectl (contexts configured), grpcurl, python3, jq, aws CLI (SSO).
# A raw s16le 16 kHz mono PCM fixture and the aegis.proto are passed via env.
#
# Cleanup is automatic on exit: the test Cognito user is deleted and the captured
# id_token files are scrubbed (they are real bearer tokens).
#
# Usage:
#   PROFILE=aegis-staging-admin \
#   PRIMARY_CTX=eu-central-1 SECONDARY_CTX=eu-west-1 \
#   POOL=eu-central-1_vLMT3QxOu CLIENT_ID=3tm1678cofqncgthiqjhauofjc \
#   COGNITO_DOMAIN=https://aegis-core-251774439261.auth.eu-central-1.amazoncognito.com \
#   COGNITO_REGION=eu-central-1 \
#   PROTO=/path/to/aegis.proto PROTO_IMPORT=/path/to/proto \
#   PCM_FIXTURE=/tmp/x.pcm GRPCURL=/tmp/grpcurl \
#   HARNESS_DIR=/path/to/scripts/verify \
#   ./ws4-app-functional-e2e.sh
#
# Exit code 0 = every face passed. Non-zero = at least one face failed or could not run.
set -uo pipefail

PROFILE="${PROFILE:-aegis-staging-admin}"
PRIMARY_CTX="${PRIMARY_CTX:-eu-central-1}"
SECONDARY_CTX="${SECONDARY_CTX:-eu-west-1}"
POOL="${POOL:-eu-central-1_vLMT3QxOu}"
CLIENT_ID="${CLIENT_ID:-3tm1678cofqncgthiqjhauofjc}"
COGNITO_DOMAIN="${COGNITO_DOMAIN:-https://aegis-core-251774439261.auth.eu-central-1.amazoncognito.com}"
COGNITO_REGION="${COGNITO_REGION:-eu-central-1}"
PROTO="${PROTO:?set PROTO to aegis.proto path}"
PROTO_IMPORT="${PROTO_IMPORT:?set PROTO_IMPORT to proto import root}"
PCM_FIXTURE="${PCM_FIXTURE:?set PCM_FIXTURE to a raw s16le 16kHz mono PCM file}"
GRPCURL="${GRPCURL:-grpcurl}"
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
NS="${NS:-aegis-core}"
EXPECT_TEXT="${EXPECT_TEXT:-the quick brown fox jumps over the lazy dog}"

GRPCWEB_PY="${HARNESS_DIR}/grpcweb.py"
PKCE_PY="${HARNESS_DIR}/cognito_pkce.py"
WORK="$(mktemp -d)"
RESULTS=()
PIDS=()
TESTUSER=""
RC=0

log()  { echo "[$(date +%H:%M:%S)] $*"; }
record() { RESULTS+=("$1|$2|$3"); }   # name | PASS/FAIL | detail

cleanup() {
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  pkill -f "port-forward svc/aegis-core" 2>/dev/null || true
  if [ -n "$TESTUSER" ]; then
    log "cleanup: deleting Cognito test user $TESTUSER"
    aws cognito-idp admin-delete-user --profile "$PROFILE" --region "$COGNITO_REGION" \
      --user-pool-id "$POOL" --username "$TESTUSER" 2>/dev/null \
      && log "cleanup: user deleted" || log "cleanup: user delete returned non-zero (may already be gone)"
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# --- Build the StreamTranscribe message file (SessionStart, one PcmChunk, END_STREAM) ---
B64="$(base64 -i "$PCM_FIXTURE" | tr -d '\n')"
cat > "$WORK/stream.json" <<EOF
{"session_start":{"session_id":"ws4-verify","tenant_id":"demo","rag_id":"","audio_format":{"sample_rate_hz":16000,"channels":1,"bits_per_sample":16},"estimated_bytes":200000000}}
{"pcm":{"pcm":"$B64","chunk_id":0,"offset_ms":0}}
{"control":{"kind":"CONTROL_KIND_END_STREAM"}}
EOF

# ============================ TEST 1 — transcription ============================
transcribe() {  # ctx local_port
  local ctx="$1" port="$2"
  kubectl --context "$ctx" -n "$NS" port-forward svc/aegis-core-engine "${port}:50051" >"$WORK/pf-eng-$ctx.log" 2>&1 &
  local pf=$!; PIDS+=("$pf")
  sleep 5
  local out
  out="$("$GRPCURL" -plaintext -proto "$PROTO" -import-path "$PROTO_IMPORT" -max-time 120 \
        -d @ "localhost:${port}" aegis.v1.Engine/StreamTranscribe < "$WORK/stream.json" 2>&1)"
  kill "$pf" 2>/dev/null || true
  local text
  text="$(echo "$out" | jq -r 'select(.transcript) | .transcript.text' 2>/dev/null | head -1 | sed 's/^ *//;s/[.]*$//')"
  if echo "$text" | grep -qi "$EXPECT_TEXT"; then
    record "transcription-$ctx" PASS "\"$text\""
  else
    record "transcription-$ctx" FAIL "got: $(echo "$out" | tr '\n' ' ' | head -c 200)"
  fi
}

log "TEST 1: transcription via Engine (both regions)"
transcribe "$PRIMARY_CTX"   50051
transcribe "$SECONDARY_CTX" 50052

# ============================ TEST 2/3 — Gateway OIDC BVA ============================
kubectl --context "$PRIMARY_CTX"   -n "$NS" port-forward svc/aegis-core-gateway 8080:8080 >"$WORK/pf-gw-p.log" 2>&1 & PIDS+=($!)
kubectl --context "$SECONDARY_CTX" -n "$NS" port-forward svc/aegis-core-gateway 8081:8080 >"$WORK/pf-gw-s.log" 2>&1 & PIDS+=($!)
sleep 6

bva() {  # label port case token_arg  -> echoes grpc-status, records PASS/FAIL vs expectation
  local label="$1" port="$2" case="$3" expect="$4" tokenfile="${5:-}"
  local out gs
  if [ -n "$tokenfile" ]; then
    out="$(python3 "$GRPCWEB_PY" "$port" "$case" "$(cat "$tokenfile")" 2>&1)"
  else
    out="$(python3 "$GRPCWEB_PY" "$port" "$case" 2>&1)"
  fi
  gs="$(echo "$out" | sed -n 's/.*grpc-status=\([0-9]*\).*/\1/p' | head -1)"
  if [ "$case" = "valid" ]; then
    # valid face must NOT be Unauthenticated(16); reaching the handler (any non-16) is a pass
    if [ -n "$gs" ] && [ "$gs" != "16" ]; then record "$label" PASS "grpc-status=$gs (passed auth)"; else record "$label" FAIL "grpc-status=$gs"; fi
  else
    if [ "$gs" = "$expect" ]; then record "$label" PASS "grpc-status=$gs"; else record "$label" FAIL "grpc-status=$gs (want $expect)"; fi
  fi
}

log "TEST 2: BVA negatives (both regions)"
for face in notoken garbage malformed; do
  bva "bva-$face-$PRIMARY_CTX"   8080 "$face" 16
  bva "bva-$face-$SECONDARY_CTX" 8081 "$face" 16
done

# --- TEST 3: PKCE id_token ---
log "TEST 3: Cognito PKCE id_token"
TESTUSER="ws4-verify-$$-$(date +%s)@example.com"
PW="Verify-WS4-$$-Aa1!xyz"
if aws cognito-idp admin-create-user --profile "$PROFILE" --region "$COGNITO_REGION" \
     --user-pool-id "$POOL" --username "$TESTUSER" --message-action SUPPRESS \
     --user-attributes Name=email,Value="$TESTUSER" Name=email_verified,Value=true >/dev/null 2>&1 \
   && aws cognito-idp admin-set-user-password --profile "$PROFILE" --region "$COGNITO_REGION" \
        --user-pool-id "$POOL" --username "$TESTUSER" --password "$PW" --permanent >/dev/null 2>&1 \
   && aws cognito-idp admin-update-user-attributes --profile "$PROFILE" --region "$COGNITO_REGION" \
        --user-pool-id "$POOL" --username "$TESTUSER" \
        --user-attributes Name=custom:tenant_id,Value=verify-tenant >/dev/null 2>&1; then
  log "test user created: $TESTUSER"
else
  record "pkce-id-token" FAIL "could not provision test user"
fi

ID_TOKEN_FILE="$WORK/id_token.txt"
if [ -n "$TESTUSER" ]; then
  COGNITO_DOMAIN="$COGNITO_DOMAIN" CLIENT_ID="$CLIENT_ID" \
    python3 "$PKCE_PY" "$TESTUSER" "$PW" "$ID_TOKEN_FILE" >"$WORK/pkce.log" 2>&1
  if [ -s "$ID_TOKEN_FILE" ]; then
    TENANT="$(python3 -c 'import sys,base64,json;t=open(sys.argv[1]).read().strip().split(".")[1];t+="="*(-len(t)%4);print(json.loads(base64.urlsafe_b64decode(t)).get("custom:tenant_id"))' "$ID_TOKEN_FILE")"
    if [ "$TENANT" = "verify-tenant" ]; then
      record "pkce-id-token-tenant" PASS "custom:tenant_id=$TENANT"
    else
      record "pkce-id-token-tenant" FAIL "tenant claim=$TENANT"
    fi
    # tampered token = valid token with last signature byte flipped
    python3 -c 'import sys;t=open(sys.argv[1]).read().strip();h,p,s=t.split(".");c="A" if s[-1]!="A" else "B";open(sys.argv[2],"w").write(h+"."+p+"."+s[:-1]+c)' "$ID_TOKEN_FILE" "$WORK/id_token_tampered.txt"
    # valid + tampered faces, both regions
    bva "bva-valid-$PRIMARY_CTX"      8080 valid    "" "$ID_TOKEN_FILE"
    bva "bva-valid-$SECONDARY_CTX"    8081 valid    "" "$ID_TOKEN_FILE"
    bva "bva-tampered-$PRIMARY_CTX"   8080 tampered 16 "$WORK/id_token_tampered.txt"
    bva "bva-tampered-$SECONDARY_CTX" 8081 tampered 16 "$WORK/id_token_tampered.txt"
  else
    record "pkce-id-token" FAIL "hosted-UI flow did not yield an id_token (see pkce.log)"
    cat "$WORK/pkce.log"
  fi
fi

# ============================ Report ============================
echo
printf '%-34s %-6s %s\n' "FACE" "RESULT" "DETAIL"
printf '%-34s %-6s %s\n' "----" "------" "------"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r name res detail <<< "$r"
  printf '%-34s %-6s %s\n' "$name" "$res" "$detail"
  [ "$res" != "PASS" ] && RC=1
done
exit $RC
