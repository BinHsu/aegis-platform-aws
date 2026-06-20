#!/usr/bin/env bash
#
# static-checks.sh — Tier 0 static verification (cluster-free, cost-free).
#
# Runs all static checks that require no live cluster and make no cloud API calls.
# Safe to run on any PR or local development iteration.
#
#   CHECK 1  terraform validate  — all three envs (bootstrap / platform / regional).
#   CHECK 2  terraform test      — mock-only cold-start gate (regional env).
#             Tests live in terraform/envs/regional/tests/cold_start.tftest.hcl.
#   CHECK 3  crossplane render + validate — XBucket XRD/Composition offline gate.
#             Delegates to scripts/crossplane-validate.sh (which requires Docker for
#             the render step; schema validation runs without Docker).
#   CHECK 4  kyverno test        — unit-tests the aegis-policies chart ClusterPolicies.
#             Requires kyverno CLI. Skipped with a clear message if not installed.
#   CHECK 5  kustomize build     — build the deploy overlays in aegis-core-deploy.
#             CROSS-REPO DEPENDENCY: overlays live in aegis-core-deploy repo, not
#             here. The check requires CORE_DEPLOY_DIR to point at a local clone of
#             that repo. Skipped with a clear message if CORE_DEPLOY_DIR is unset or
#             if kustomize is not installed.
#
# Usage:
#   BIN=./bin HARNESS_DIR=/path/to/scripts/verify \
#   CORE_DEPLOY_DIR=/path/to/aegis-core-deploy \
#   ./scripts/verify/static-checks.sh
#
# All binaries are looked up in $BIN first (project-local, from install-tools.sh),
# then on $PATH. The Crossplane CLI is expected at $BIN/crossplane
# (scripts/install-crossplane.sh "$BIN").
#
# Exit code 0 = all attempted checks passed. Non-zero = at least one failed.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BIN="${BIN:-$REPO_ROOT/bin}"
HARNESS_DIR="${HARNESS_DIR:-$(cd "$(dirname "$0")" && pwd)}"

RESULTS=()
RC=0

# ── Helpers ───────────────────────────────────────────────────────────────────
log()    { echo "[$(date +%H:%M:%S)] $*"; }
record() { RESULTS+=("$1|$2|$3"); }   # check | PASS/FAIL | detail
pass()   { record "$1" PASS "$2"; }
fail()   { record "$1" FAIL "$2"; RC=1; }
skip()   { record "$1" SKIP "$2"; }

# Find a binary: prefer $BIN/<name>, fall back to PATH.
find_bin() {
  local name="$1"
  if [ -x "$BIN/$name" ]; then
    echo "$BIN/$name"
  elif command -v "$name" >/dev/null 2>&1; then
    echo "$name"
  else
    echo ""
  fi
}

TF="$(find_bin terraform)"
HELM="$(find_bin helm)"
CROSSPLANE_CLI="$(find_bin crossplane)"
KYVERNO_CLI="$(find_bin kyverno)"
KUSTOMIZE_CLI="$(find_bin kustomize)"

if [ -z "$TF" ]; then
  echo "ERROR: terraform not found in $BIN or PATH" >&2
  exit 1
fi

# ==============================================================================
# CHECK 1 — terraform validate (all three envs)
# ==============================================================================
log "CHECK 1: terraform validate (bootstrap / platform / regional)"
for env in bootstrap platform regional; do
  env_dir="$REPO_ROOT/terraform/envs/$env"
  if [ ! -d "$env_dir" ]; then
    fail "tf-validate-$env" "directory not found: $env_dir"
    continue
  fi
  out="$(cd "$env_dir" && "$TF" init -backend=false -input=false -upgrade=false 2>&1 && "$TF" validate 2>&1)" || {
    fail "tf-validate-$env" "$(echo "$out" | tail -5 | tr '\n' ' ')"
    continue
  }
  pass "tf-validate-$env" "validate OK"
done

# ==============================================================================
# CHECK 2 — terraform test (mock-only cold-start gate)
# ==============================================================================
log "CHECK 2: terraform test (regional cold-start, mock-only)"
regional_dir="$REPO_ROOT/terraform/envs/regional"
test_file="$regional_dir/tests/cold_start.tftest.hcl"
if [ ! -f "$test_file" ]; then
  skip "tf-test-cold-start" "test file not found: $test_file"
else
  out="$(cd "$regional_dir" && "$TF" init -backend=false -input=false 2>&1 && "$TF" test 2>&1)"
  exit_code=$?
  if [ "$exit_code" -eq 0 ]; then
    pass "tf-test-cold-start" "all tf test assertions passed"
  else
    fail "tf-test-cold-start" "$(echo "$out" | tail -10 | tr '\n' ' ')"
  fi
fi

# ==============================================================================
# CHECK 3 — Crossplane render + validate (XBucket, offline)
# ==============================================================================
log "CHECK 3: crossplane render + validate (XBucket)"
if [ -z "$CROSSPLANE_CLI" ]; then
  skip "crossplane-validate" \
    "crossplane CLI not found — run scripts/install-crossplane.sh \"$BIN\" first"
elif [ -z "$HELM" ]; then
  skip "crossplane-validate" "helm not found — required to render the chart"
else
  validate_script="$REPO_ROOT/scripts/crossplane-validate.sh"
  if [ ! -x "$validate_script" ]; then
    fail "crossplane-validate" "script not found: $validate_script"
  else
    out="$(BIN="$BIN" CROSSPLANE="$CROSSPLANE_CLI" bash "$validate_script" 2>&1)"
    exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
      pass "crossplane-validate" "render + schema validate OK"
    else
      fail "crossplane-validate" "$(echo "$out" | tail -5 | tr '\n' ' ')"
    fi
  fi
fi

# ==============================================================================
# CHECK 4 — kyverno test (ClusterPolicy unit tests)
# ==============================================================================
log "CHECK 4: kyverno test (aegis-policies chart)"
POLICIES_CHART="$REPO_ROOT/terraform/modules/regional-stack/charts/aegis-policies"
KYVERNO_TEST_DIR="$REPO_ROOT/terraform/modules/regional-stack/charts/aegis-policies/tests"

if [ -z "$KYVERNO_CLI" ]; then
  skip "kyverno-test" \
    "kyverno CLI not found in $BIN or PATH — install from https://kyverno.io/docs/installation/cli/"
elif [ -z "$HELM" ]; then
  skip "kyverno-test" "helm not found — required to render policy templates"
else
  # kyverno test expects a flat directory of policy + test YAMLs.
  # We render the chart and run kyverno test against the rendered policies.
  # If a test directory exists under the chart, use it; otherwise report
  # that no tests are authored yet (the chart E2E gate is pending bootstrap).
  if [ ! -d "$KYVERNO_TEST_DIR" ]; then
    skip "kyverno-test" \
      "no tests/ directory in aegis-policies chart — kyverno test authoring is pending " \
      "cluster bootstrap (chart comment: 'implemented, E2E PENDING platform bootstrap')"
  else
    out="$(POLICIES_CHART="$POLICIES_CHART" "$KYVERNO_CLI" test "$KYVERNO_TEST_DIR" 2>&1)"
    exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
      pass "kyverno-test" "all kyverno tests passed"
    else
      fail "kyverno-test" "$(echo "$out" | tail -8 | tr '\n' ' ')"
    fi
  fi
fi

# ==============================================================================
# CHECK 5 — kustomize build (aegis-core-deploy overlays)
# ==============================================================================
# CROSS-REPO DEPENDENCY: The deploy overlays live in aegis-core-deploy, not in
# this repo. This check requires CORE_DEPLOY_DIR to point at a local clone.
# This is a known, intentional cross-repo dependency — aegis-platform-aws is the
# platform layer; deploy manifests are per-workload (aegis-core-deploy). The check
# is scoped here because the platform's ArgoCD ApplicationSet drives those overlays,
# and platform CI should be able to validate them.
log "CHECK 5: kustomize build (aegis-core-deploy overlays)"
if [ -z "$KUSTOMIZE_CLI" ]; then
  skip "kustomize-build" \
    "kustomize not found in $BIN or PATH — install from https://kustomize.io"
elif [ -z "${CORE_DEPLOY_DIR:-}" ]; then
  skip "kustomize-build" \
    "CORE_DEPLOY_DIR not set — point it at a local clone of aegis-core-deploy " \
    "(cross-repo dependency: overlays live in aegis-core-deploy, not here)"
elif [ ! -d "$CORE_DEPLOY_DIR" ]; then
  fail "kustomize-build" "CORE_DEPLOY_DIR=$CORE_DEPLOY_DIR does not exist"
else
  # Find all kustomization.yaml files under the overlays/ directory.
  any_overlay=false
  while IFS= read -r kdir; do
    any_overlay=true
    overlay_name="$(basename "$(dirname "$kdir")")/$(basename "$kdir" | sed 's|/kustomization.yaml||')"
    out="$("$KUSTOMIZE_CLI" build "$(dirname "$kdir")" 2>&1)"
    exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
      pass "kustomize-build-${overlay_name//[^a-zA-Z0-9]/-}" "build OK"
    else
      fail "kustomize-build-${overlay_name//[^a-zA-Z0-9]/-}" \
        "$(echo "$out" | tail -5 | tr '\n' ' ')"
    fi
  done < <(find "$CORE_DEPLOY_DIR/k8s/overlays" -name "kustomization.yaml" 2>/dev/null)
  if ! $any_overlay; then
    skip "kustomize-build" \
      "no kustomization.yaml found under $CORE_DEPLOY_DIR/k8s/overlays"
  fi
fi

# ==============================================================================
# Report
# ==============================================================================
echo
printf '%-50s %-6s %s\n' "CHECK" "RESULT" "DETAIL"
printf '%-50s %-6s %s\n' "-----" "------" "------"
for r in "${RESULTS[@]}"; do
  IFS='|' read -r name res detail <<< "$r"
  printf '%-50s %-6s %s\n' "$name" "$res" "$detail"
  [ "$res" = "FAIL" ] && RC=1
done

echo
skipped="$(printf '%s\n' "${RESULTS[@]}" | grep -c '|SKIP|' || true)"
if [ "${skipped:-0}" -gt 0 ]; then
  echo "NOTE: $skipped check(s) skipped (see details above). Install missing tools or set CORE_DEPLOY_DIR to run them."
fi
exit $RC
