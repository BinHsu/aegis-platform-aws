#!/usr/bin/env bash
# scripts/crossplane-validate.sh
#
# OFFLINE composition gate for the WS4 Axis A XBucket stack (ADR-22). Renders the
# chart's Composition with Helm, then runs the Crossplane CLI offline checks:
#
#   1. crossplane resource validate (XRD schema)       — the example XR is a
#      structurally valid XBucket (catches the fix-B-class schema mismatch BEFORE
#      a billable apply: RETRO §7B).
#   2. crossplane resource validate (+ provider schemas) — the XR + Composition
#      validate against the downloaded provider-aws-s3 + function schemas (0
#      missing schemas proves the s3.aws.m.upbound.io group + package refs are
#      real).
#   3. crossplane composition render                    — renders the composed
#      Bucket + BucketPublicAccessBlock. REQUIRES DOCKER to run the function pod
#      (the function executes in a container). Skipped with a clear message when
#      no Docker daemon is reachable; CI runners have Docker, so the gate runs it
#      there.
#
# Network: steps 1–2 download the crossplane core + provider + function SCHEMA
# packages once (cached under ~/.crossplane/cache or --cache-dir). They need
# network but NOT a cluster and NOT Docker. Step 3 needs Docker.
#
# Usage: BIN=./bin ./scripts/crossplane-validate.sh
#   CROSSPLANE=<path>   override the CLI binary (default $BIN/crossplane)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${BIN:-$REPO_ROOT/bin}"
CROSSPLANE="${CROSSPLANE:-$BIN/crossplane}"
CHART="$REPO_ROOT/terraform/modules/regional-stack/charts/aegis-xrds-v2"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [ ! -x "$CROSSPLANE" ]; then
  echo "ERROR: crossplane CLI not found at $CROSSPLANE — run scripts/install-crossplane.sh \"$BIN\" first." >&2
  exit 1
fi

echo "==> Rendering the XBucket chart with Helm (example install values)"
# Example install-time values; the gate validates the SHAPE, not real account IDs.
HELM_ARGS=(--set region=eu-central-1 --set accountId=123456789012 --set bucketPrefix=aegis-wl)
helm template aegis-xrds-v2 "$CHART" "${HELM_ARGS[@]}" \
  --show-only templates/xrd-bucket.yaml > "$WORK/xrd.yaml"
helm template aegis-xrds-v2 "$CHART" "${HELM_ARGS[@]}" \
  --show-only templates/composition-bucket.yaml > "$WORK/composition.yaml"
cp "$CHART/examples/xbucket.yaml" "$WORK/xr.yaml"

echo "==> [1/3] resource validate: example XR against the XRD schema"
"$CROSSPLANE" resource validate "$WORK/xrd.yaml" "$WORK/xr.yaml"

echo "==> [2/3] resource validate: XR + Composition against provider-aws-s3 + function schemas"
# Build the extension bundle: XRD + Composition + the provider/function packages
# whose schemas the composed Bucket / BucketPublicAccessBlock resolve against.
{
  cat "$WORK/xrd.yaml"
  echo "---"
  cat "$WORK/composition.yaml"
  cat <<'EOF'
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-s3
spec:
  package: xpkg.upbound.io/upbound/provider-aws-s3:v2.6.1
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-patch-and-transform
spec:
  package: xpkg.crossplane.io/crossplane-contrib/function-patch-and-transform:v0.10.6
EOF
} > "$WORK/extensions.yaml"
"$CROSSPLANE" resource validate "$WORK/extensions.yaml" "$WORK/xr.yaml"

echo "==> [3/3] composition render (needs Docker to run the function pod)"
if docker info >/dev/null 2>&1; then
  "$CROSSPLANE" composition render "$WORK/xr.yaml" "$WORK/composition.yaml" "$CHART/render/functions.yaml"
  echo "    render OK"
else
  echo "    SKIP: no Docker daemon reachable. composition render runs the"
  echo "    function in a container; steps [1] and [2] (schema validation) ran"
  echo "    WITHOUT Docker and are the gate's offline core. CI runners provide"
  echo "    Docker, so render runs there. (Honest note: a local run on a"
  echo "    Docker-free host validates schemas but does not render composed MRs.)"
fi

echo "==> crossplane offline validation complete."
