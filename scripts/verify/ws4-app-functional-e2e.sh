#!/usr/bin/env bash
#
# ws4-app-functional-e2e.sh — WS4 §7D application-functional E2E verification
# harness (laptop port-forward tier).
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
# PORT-FORWARD NOTE: This script uses laptop kubectl port-forwards. For a fully
# hands-off alternative that needs no port-forwards at all, use the Tier 2
# in-cluster verifier Job: scripts/verify/run-incluster-verify.sh.
#
# Requirements: kubectl (contexts configured), grpcurl, python3, jq, aws CLI (SSO).
# A raw s16le 16 kHz mono PCM fixture and the aegis.proto are passed via env.
#
# Cleanup is automatic on exit: each port-forward is killed by its tracked PID
# (no scattergun pkill), the test Cognito user is deleted, and the captured
# id_token files are scrubbed (they are real bearer tokens).
#
# Cognito config (POOL, CLIENT_ID, COGNITO_DOMAIN) is derived automatically from
# `terraform output` if PLATFORM_TF_DIR is set; override by setting each var
# explicitly for faster iteration.
#
# Usage (auto-derive Cognito config):
#   PROFILE=aegis-staging-admin \
#   PRIMARY_CTX=eu-central-1 SECONDARY_CTX=eu-west-1 \
#   PLATFORM_TF_DIR=/path/to/terraform/envs/platform \
#   PROTO=/path/to/aegis.proto PROTO_IMPORT=/path/to/proto \
#   PCM_FIXTURE=/tmp/x.pcm GRPCURL=/tmp/grpcurl \
#   HARNESS_DIR=/path/to/scripts/verify \
#   ./ws4-app-functional-e2e.sh
#
# Usage (explicit overrides, no terraform needed):
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
# Exit code 0 = every face passed. Non-zero = at least one face failed or could
# not run.
set -uo pipefail

PROFILE="${PROFILE:-aegis-staging-admin}"
PRIMARY_CTX="${PRIMARY_CTX:-eu-central-1}"
SECONDARY_CTX="${SECONDARY_CTX:-eu-west-1}"
COGNITO_REGION="${COGNITO_REGION:-eu-central-1}"
PROTO="${PROTO:?set PROTO to aegis.proto path}"
PROTO_IMPORT="${PROTO_IMPORT:?set PROTO_IMPORT to proto import root}"
PCM_FIXTURE="${PCM_FIXTURE:?set PCM_FIXTURE to a raw s16le 16kHz mono PCM file}"
GRPCURL="${GRPCURL:-grpcurl}"
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")" && pwd)}"
NS="${NS:-aegis-core}"
EXPECT_TEXT="${EXPECT_TEXT:-the quick brown fox jumps over the lazy dog}"

# Port-forward readiness timeout in seconds (replaces fixed sleep 5/6).
PF_TIMEOUT="${PF_TIMEOUT:-20}"

GRPCWEB_PY="${HARNESS_DIR}/grpcweb.py"
PKCE_PY="${HARNESS_DIR}/cognito_pkce.py"
WORK="$(mktemp -d)"
RESULTS=()
PIDS=()
TESTUSER=""
RC=0

# ── Dependency check ────────────────────────────────────────────────────────────
check_deps() {
  local missing=()
  local cmd
  for cmd in python3 jq aws kubectl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  # GRPCURL may be a path rather than a bare command name.
  if ! command -v "$GRPCURL" >/dev/null 2>&1 && [ ! -x "$GRPCURL" ]; then
    missing+=("grpcurl (GRPCURL=$GRPCURL)")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: missing dependencies: ${missing[*]}" >&2
    exit 1
  fi
}
check_deps

log()    { echo "[$(date +%H:%M:%S)] $*"; }
record() { RESULTS+=("$1|$2|$3"); }   # name | PASS/FAIL | detail

# ── Cleanup — PID-tracked, no scattergun pkill ─────────────────────────────────
cleanup() {
  local p
  for p in "${PIDS[@]:-}"; do
    kill "$p" 2>/dev/null || true
  done
  if [ -n "$TESTUSER" ]; then
    log "cleanup: deleting Cognito test user $TESTUSER"
    if aws cognito-idp admin-delete-user \
      --profile "$PROFILE" --region "$COGNITO_REGION" \
      --user-pool-id "$POOL" --username "$TESTUSER" 2>/dev/null; then
      log "cleanup: user deleted"
    else
      log "cleanup: user delete returned non-zero (may already be gone)"
    fi
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── Derive Cognito config from terraform output (if PLATFORM_TF_DIR is set) ────
if [ -n "${PLATFORM_TF_DIR:-}" ]; then
  log "Deriving Cognito config from terraform output in $PLATFORM_TF_DIR"
  _issuer="$(cd "$PLATFORM_TF_DIR" && terraform output -raw cognito_issuer 2>/dev/null)"
  # Pool ID is the last path segment of the issuer URL.
  POOL="${POOL:-${_issuer##*/}}"
  CLIENT_ID="${CLIENT_ID:-$(cd "$PLATFORM_TF_DIR" && terraform output -raw cognito_app_client_id 2>/dev/null)}"
  _hosted_ui="$(cd "$PLATFORM_TF_DIR" && terraform output -raw cognito_hosted_ui_domain 2>/dev/null)"
  COGNITO_DOMAIN="${COGNITO_DOMAIN:-https://$_hosted_ui}"
  COGNITO_REGION="${COGNITO_REGION:-$(cd "$PLATFORM_TF_DIR" && terraform output -raw aws_region 2>/dev/null)}"
fi

# Ensure required Cognito vars are present (from terraform derivation or caller).
: "${POOL:?set POOL (user pool id) or set PLATFORM_TF_DIR}"
: "${CLIENT_ID:?set CLIENT_ID or set PLATFORM_TF_DIR}"
: "${COGNITO_DOMAIN:?set COGNITO_DOMAIN or set PLATFORM_TF_DIR}"

# ── Wait for a local port to accept TCP connections ──────────────────────────────
wait_for_port() {  # host port
  local host="$1" port="$2" deadline
  deadline=$(( $(date +%s) + PF_TIMEOUT ))
  while ! (echo >/dev/tcp/"$host"/"$port") 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "ERROR: port $port on $host did not become ready within ${PF_TIMEOUT}s" >&2
      return 1
    fi
    sleep 1
  done
}

# ── Find a free ephemeral port ────────────────────────────────────────────────────
free_port() {
  python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()"
}

# ── Build the StreamTranscribe message file ──────────────────────────────────────
B64="$(base64 -i "$PCM_FIXTURE" | tr -d '\n')"
cat > "$WORK/stream.json" <<EOF
{"session_start":{"session_id":"ws4-verify","tenant_id":"demo","rag_id":"","audio_format":{"sample_rate_hz":16000,"channels":1,"bits_per_sample":16},"estimated_bytes":200000000}}
{"pcm":{"pcm":"$B64","chunk_id":0,"offset_ms":0}}
{"control":{"kind":"CONTROL_KIND_END_STREAM"}}
EOF

# ============================ TEST 1 — transcription ============================
transcribe() {  # ctx
  local ctx="$1"
  local port
  port="$(free_port)"
  kubectl --context "$ctx" -n "$NS" \
    port-forward svc/aegis-core-engine "${port}:50051" \
    >"$WORK/pf-eng-$ctx.log" 2>&1 &
  local pf=$!
  PIDS+=("$pf")
  log "transcription port-forward PID=$pf port=$port ctx=$ctx"
  if ! wait_for_port localhost "$port"; then
    record "transcription-$ctx" FAIL "port-forward did not become ready within ${PF_TIMEOUT}s"
    kill "$pf" 2>/dev/null || true
    return
  fi
  local out
  out="$("$GRPCURL" -plaintext -proto "$PROTO" -import-path "$PROTO_IMPORT" \
        -max-time 120 -d @ "localhost:${port}" \
        aegis.v1.Engine/StreamTranscribe < "$WORK/stream.json" 2>&1)"
  kill "$pf" 2>/dev/null || true
  local text
  text="$(echo "$out" | jq -r 'select(.transcript) | .transcript.text' 2>/dev/null \
          | head -1 | sed 's/^ *//;s/[.]*$//')"
  if echo "$text" | grep -qi "$EXPECT_TEXT"; then
    record "transcription-$ctx" PASS "\"$text\""
  else
    record "transcription-$ctx" FAIL "got: $(echo "$out" | tr '\n' ' ' | head -c 200)"
  fi
}

log "TEST 1: transcription via Engine (both regions)"
transcribe "$PRIMARY_CTX"
transcribe "$SECONDARY_CTX"

# ============================ TEST 2/3 — Gateway OIDC BVA ============================
GW_PORT_P="$(free_port)"
GW_PORT_S="$(free_port)"

kubectl --context "$PRIMARY_CTX" -n "$NS" \
  port-forward svc/aegis-core-gateway "${GW_PORT_P}:8080" \
  >"$WORK/pf-gw-p.log" 2>&1 &
PIDS+=($!)

kubectl --context "$SECONDARY_CTX" -n "$NS" \
  port-forward svc/aegis-core-gateway "${GW_PORT_S}:8080" \
  >"$WORK/pf-gw-s.log" 2>&1 &
PIDS+=($!)

log "gateway port-forward ports: primary=$GW_PORT_P secondary=$GW_PORT_S"
wait_for_port localhost "$GW_PORT_P" || record "bva-gateway-primary" FAIL "port-forward not ready"
wait_for_port localhost "$GW_PORT_S" || record "bva-gateway-secondary" FAIL "port-forward not ready"

bva() {  # label port case expect [tokenfile]
  local label="$1" port="$2" case="$3" expect="$4" tokenfile="${5:-}"
  local out gs
  if [ -n "$tokenfile" ]; then
    out="$(python3 "$GRPCWEB_PY" --host localhost --port "$port" \
           "$case" "$(cat "$tokenfile")" 2>&1)"
  else
    out="$(python3 "$GRPCWEB_PY" --host localhost --port "$port" "$case" 2>&1)"
  fi
  gs="$(echo "$out" | sed -n 's/.*grpc-status=\([0-9]*\).*/\1/p' | head -1)"
  if [ "$case" = "valid" ]; then
    # valid face must NOT be Unauthenticated(16); any non-16 means auth passed
    if [ -n "$gs" ] && [ "$gs" != "16" ]; then
      record "$label" PASS "grpc-status=$gs (passed auth)"
    else
      record "$label" FAIL "grpc-status=$gs"
    fi
  else
    if [ "$gs" = "$expect" ]; then
      record "$label" PASS "grpc-status=$gs"
    else
      record "$label" FAIL "grpc-status=$gs (want $expect)"
    fi
  fi
}

log "TEST 2: BVA negatives (both regions)"
for face in notoken garbage malformed; do
  bva "bva-$face-$PRIMARY_CTX"   "$GW_PORT_P" "$face" 16
  bva "bva-$face-$SECONDARY_CTX" "$GW_PORT_S" "$face" 16
done

# --- TEST 3: PKCE id_token ---
log "TEST 3: Cognito PKCE id_token"
TESTUSER="ws4-verify-$$-$(date +%s)@example.com"
PW="Verify-WS4-$$-Aa1!xyz"
if aws cognito-idp admin-create-user \
     --profile "$PROFILE" --region "$COGNITO_REGION" \
     --user-pool-id "$POOL" --username "$TESTUSER" \
     --message-action SUPPRESS \
     --user-attributes Name=email,Value="$TESTUSER" Name=email_verified,Value=true \
     >/dev/null 2>&1 \
   && aws cognito-idp admin-set-user-password \
        --profile "$PROFILE" --region "$COGNITO_REGION" \
        --user-pool-id "$POOL" --username "$TESTUSER" \
        --password "$PW" --permanent >/dev/null 2>&1 \
   && aws cognito-idp admin-update-user-attributes \
        --profile "$PROFILE" --region "$COGNITO_REGION" \
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
    TENANT="$(python3 - "$ID_TOKEN_FILE" <<'PYEOF'
import sys, base64, json
seg = open(sys.argv[1]).read().strip().split(".")[1]
seg += "=" * (-len(seg) % 4)
print(json.loads(base64.urlsafe_b64decode(seg)).get("custom:tenant_id"))
PYEOF
)"
    if [ "$TENANT" = "verify-tenant" ]; then
      record "pkce-id-token-tenant" PASS "custom:tenant_id=$TENANT"
    else
      record "pkce-id-token-tenant" FAIL "tenant claim=$TENANT"
    fi
    # Tamper the token via the grpcweb.tamper() helper (single source of truth).
    python3 - "$HARNESS_DIR" "$ID_TOKEN_FILE" "$WORK/id_token_tampered.txt" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from grpcweb import tamper
raw = open(sys.argv[2]).read().strip()
open(sys.argv[3], "w").write(tamper(raw))
PYEOF
    # valid + tampered faces, both regions
    bva "bva-valid-$PRIMARY_CTX"      "$GW_PORT_P" valid    "" "$ID_TOKEN_FILE"
    bva "bva-valid-$SECONDARY_CTX"    "$GW_PORT_S" valid    "" "$ID_TOKEN_FILE"
    bva "bva-tampered-$PRIMARY_CTX"   "$GW_PORT_P" tampered 16 "$WORK/id_token_tampered.txt"
    bva "bva-tampered-$SECONDARY_CTX" "$GW_PORT_S" tampered 16 "$WORK/id_token_tampered.txt"
  else
    record "pkce-id-token" FAIL "hosted-UI flow did not yield an id_token (see pkce.log)"
    cat "$WORK/pkce.log"
  fi
fi

# ============================ Report ============================
echo
printf '%-38s %-6s %s\n' "FACE" "RESULT" "DETAIL"
printf '%-38s %-6s %s\n' "----" "------" "------"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r name res detail <<< "$r"
  printf '%-38s %-6s %s\n' "$name" "$res" "$detail"
  [ "$res" != "PASS" ] && RC=1
done
exit $RC
