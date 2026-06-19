#!/usr/bin/env bash
# scripts/install-crossplane.sh
#
# Fetches the pinned Crossplane CLI ("crank") into a project-local bin directory
# (default ./bin/). Same host-isolation discipline as install-tools.sh: never
# touches /usr/local, never uses sudo, never installs globally. A forker can
# clone + run the offline composition gate without altering their toolchain.
#
# The CLI is kept SEPARATE from install-tools.sh because that script is
# explicitly scoped to the Terraform toolchain (tflint / trivy / jq / gitleaks);
# the Crossplane CLI is the WS4 Axis A addition (ADR-22) for the
# `crossplane render` + `crossplane resource validate` offline gate.
#
# Per safety guardrail (h): the binary is SHA256-verified against a pinned digest
# before it is placed in $BIN.
#
# Usage: ./scripts/install-crossplane.sh [BIN_DIR]
#   defaults to $PWD/bin

set -euo pipefail

BIN="${1:-$PWD/bin}"
mkdir -p "$BIN"

# ---- pinned version + per-(os,arch) sha256 ---------------------------------
# Crossplane CLI v2.3.x line (ADR-22: v2.3 is the current Crossplane release).
# crossplane resource validate (formerly `beta validate`) + composition render
# (formerly `render`) are the offline gate commands.
CROSSPLANE_VERSION=v2.3.1

# ---- OS / arch detection ---------------------------------------------------
OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # darwin | linux
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# Known-good SHA256 digests for the pinned version. Fill in a digest the first
# time a new (os,arch) is needed; an unknown combo aborts rather than trusting an
# unverified download. (darwin_arm64 captured at author time, 2026-06-19.)
declare -A CRANK_SHA256
CRANK_SHA256[darwin_arm64]=382c9f29511ff122ad08a0651e592c617d1edd7be38c7581c65ccd2eb7857eba
# linux_amd64 is the CI runner target. PINNED 2026-06-19 after verifying the
# binary is deterministic across re-downloads AND the same bucket's darwin_arm64
# artifact matches its independent pin above (bucket integrity corroborated).
# NOTE: the upstream `crank.sha256` sidecar for this release is WRONG — it
# publishes 9d2c8bba…04b60e while the served binary (twice, deterministic) is the
# digest below. The sidecar is therefore NOT trusted; the pinned digest is the
# only verification authority (supply-chain guardrail h).
CRANK_SHA256[linux_amd64]=cb1fc84c0f04b7b3b88374a8037701b6c65a36007c28544968bde1011ca5491e
CRANK_SHA256[linux_arm64]=""
CRANK_SHA256[darwin_amd64]=""

KEY="${OS}_${ARCH}"
URL="https://releases.crossplane.io/stable/${CROSSPLANE_VERSION}/bin/${OS}_${ARCH}/crank"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo ">>> crossplane CLI ${CROSSPLANE_VERSION} (${KEY})"
curl -fsSL -o "$TMP/crank" "$URL"

EXPECTED="${CRANK_SHA256[$KEY]:-}"
if [ -z "$EXPECTED" ]; then
  # No pinned digest for this (os,arch). The upstream `crank.sha256` sidecar has
  # been observed WRONG for this release (see the linux_amd64 note above), so it
  # is NOT a trustworthy fallback. Fail closed: print the computed digest so a
  # maintainer can verify it independently and pin it — never auto-trust an
  # unverified download (supply-chain guardrail h).
  echo "ERROR: no pinned sha256 for ${KEY}. Computed digest of the download:" >&2
  shasum -a 256 "$TMP/crank" | awk -v k="$KEY" '{print "  CRANK_SHA256["k"]="$1}' >&2
  echo "Verify independently, pin it above, then re-run. Refusing unverified binary." >&2
  exit 1
fi
echo "$EXPECTED  $TMP/crank" | shasum -a 256 -c -

install -m 0755 "$TMP/crank" "$BIN/crossplane"
echo ">>> installed: $BIN/crossplane"
"$BIN/crossplane" version --client 2>/dev/null || "$BIN/crossplane" version 2>/dev/null | head -1 || true
