#!/usr/bin/env bash
# scripts/install-tools.sh
#
# Fetches pinned dev tools into a project-local bin directory (default ./bin/).
# Per "Host isolation discipline": this script never touches /usr/local, never
# touches ~/.terraform.d/plugins, and never uses sudo. Reviewer can clone +
# `make dev-setup` without conflicting with their existing toolchain.
#
# Per inherited safety guardrail (h): each binary is fetched from its upstream
# GitHub release and SHA256-verified against the release's published checksums
# file before being placed in $BIN. Hardening path (not implemented for the
# take-home scope): cosign / GPG signature verification of the checksums file
# itself; see docs/tradeoffs.md once written.
#
# Usage: ./scripts/install-tools.sh [BIN_DIR]
#   defaults to $PWD/bin

set -euo pipefail

BIN="${1:-$PWD/bin}"
mkdir -p "$BIN"

# ---- pinned versions -------------------------------------------------------
TFLINT_VERSION=v0.53.0
TFSEC_VERSION=v1.28.11
KUBECONFORM_VERSION=v0.6.7
HADOLINT_VERSION=v2.12.0
JQ_VERSION=1.7.1
GITLEAKS_VERSION=8.18.4
KUSTOMIZE_VERSION=5.4.3

# ---- OS / arch detection ---------------------------------------------------
OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # darwin | linux
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

# Hadolint asset names use CapitalCase OS and x86_64/arm64 arch.
# Known platform constraint: hadolint v2.12.0 ships no native Darwin/arm64
# binary, and the Darwin/x86_64 build segfaults under Rosetta 2 on Apple
# Silicon (reproduced). We therefore skip the local install on darwin/arm64
# and rely on the Linux runner in CI (where Linux/arm64 + Linux/x86_64 builds
# work natively). Local Dockerfile linting on darwin/arm64 falls back to:
#     docker run --rm -i hadolint/hadolint < Dockerfile
case "$OS" in
  darwin) HADOLINT_OS=Darwin ;;
  linux)  HADOLINT_OS=Linux ;;
esac
case "$ARCH" in
  amd64) HADOLINT_ARCH=x86_64 ;;
  arm64) HADOLINT_ARCH=arm64 ;;
esac
SKIP_HADOLINT=false
if [ "$OS" = "darwin" ] && [ "$ARCH" = "arm64" ]; then
  SKIP_HADOLINT=true
fi

# ---- tmp workdir, auto-cleanup --------------------------------------------
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cd "$TMP"

# ---- verify_sha256 ARCHIVE CHECKSUM_FILE -----------------------------------
# Extracts the line matching ARCHIVE from CHECKSUM_FILE and feeds it to
# `shasum -a 256 -c`. Aborts script on mismatch via set -e.
verify_sha256() {
  local archive="$1" checksum_file="$2"
  local line
  line=$(grep -E "[[:space:]]\\*?${archive}\$" "$checksum_file" || true)
  if [ -z "$line" ]; then
    echo "ERROR: no checksum entry for ${archive} in ${checksum_file}" >&2
    exit 1
  fi
  echo "$line" | shasum -a 256 -c -
}

# ---- tflint ----------------------------------------------------------------
echo ">>> tflint ${TFLINT_VERSION} (${OS}/${ARCH})"
TFLINT_ZIP="tflint_${OS}_${ARCH}.zip"
curl -fsSL -o "$TFLINT_ZIP" \
  "https://github.com/terraform-linters/tflint/releases/download/${TFLINT_VERSION}/${TFLINT_ZIP}"
curl -fsSL -o tflint_checksums.txt \
  "https://github.com/terraform-linters/tflint/releases/download/${TFLINT_VERSION}/checksums.txt"
verify_sha256 "$TFLINT_ZIP" tflint_checksums.txt
unzip -o -q "$TFLINT_ZIP" tflint -d "$BIN"
chmod +x "$BIN/tflint"

# ---- tfsec -----------------------------------------------------------------
echo ">>> tfsec ${TFSEC_VERSION} (${OS}/${ARCH})"
TFSEC_BIN="tfsec-${OS}-${ARCH}"
curl -fsSL -o "$TFSEC_BIN" \
  "https://github.com/aquasecurity/tfsec/releases/download/${TFSEC_VERSION}/${TFSEC_BIN}"
curl -fsSL -o tfsec_checksums.txt \
  "https://github.com/aquasecurity/tfsec/releases/download/${TFSEC_VERSION}/tfsec_checksums.txt"
verify_sha256 "$TFSEC_BIN" tfsec_checksums.txt
mv "$TFSEC_BIN" "$BIN/tfsec"
chmod +x "$BIN/tfsec"

# ---- kubeconform -----------------------------------------------------------
echo ">>> kubeconform ${KUBECONFORM_VERSION} (${OS}/${ARCH})"
KUBECONFORM_TGZ="kubeconform-${OS}-${ARCH}.tar.gz"
curl -fsSL -o "$KUBECONFORM_TGZ" \
  "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/${KUBECONFORM_TGZ}"
curl -fsSL -o CHECKSUMS \
  "https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/CHECKSUMS"
verify_sha256 "$KUBECONFORM_TGZ" CHECKSUMS
tar -xzf "$KUBECONFORM_TGZ" -C "$BIN" kubeconform
chmod +x "$BIN/kubeconform"

# ---- hadolint --------------------------------------------------------------
if [ "$SKIP_HADOLINT" = "true" ]; then
  echo ">>> hadolint SKIPPED on darwin/arm64 (no native build, Rosetta segfaults)"
  echo "    local Dockerfile lint: docker run --rm -i hadolint/hadolint < Dockerfile"
  echo "    CI (Linux runner) installs the native build via this same script"
else
  echo ">>> hadolint ${HADOLINT_VERSION} (${HADOLINT_OS}/${HADOLINT_ARCH})"
  HADOLINT_BIN="hadolint-${HADOLINT_OS}-${HADOLINT_ARCH}"
  curl -fsSL -o "$HADOLINT_BIN" \
    "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${HADOLINT_BIN}"
  curl -fsSL -o "${HADOLINT_BIN}.sha256" \
    "https://github.com/hadolint/hadolint/releases/download/${HADOLINT_VERSION}/${HADOLINT_BIN}.sha256"
  # hadolint's .sha256 file is single-line "<sha>  <filename>"; feed directly.
  shasum -a 256 -c "${HADOLINT_BIN}.sha256"
  mv "$HADOLINT_BIN" "$BIN/hadolint"
  chmod +x "$BIN/hadolint"
fi

# ---- jq -------------------------------------------------------------------
# Used by Makefile + GH Actions workflows to parse regions.auto.tfvars.json
# (single source of truth for region topology). jq's release assets use a
# different naming convention again: jq-macos-arm64 / jq-linux-amd64 etc.
echo ">>> jq ${JQ_VERSION} (${OS}/${ARCH})"
case "$OS" in
  darwin) JQ_OS=macos ;;
  linux)  JQ_OS=linux ;;
esac
JQ_BIN="jq-${JQ_OS}-${ARCH}"
curl -fsSL -o "$JQ_BIN" \
  "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/${JQ_BIN}"
curl -fsSL -o sha256sum.txt \
  "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/sha256sum.txt"
verify_sha256 "$JQ_BIN" sha256sum.txt
mv "$JQ_BIN" "$BIN/jq"
chmod +x "$BIN/jq"

# ---- gitleaks --------------------------------------------------------------
# Secret scanner — used by the pre-commit hook (.githooks/pre-commit) and
# the gitleaks CI job. Asset naming: gitleaks_<ver>_<os>_<arch>.tar.gz,
# arch token is x64 (not amd64) / arm64.
echo ">>> gitleaks ${GITLEAKS_VERSION} (${OS}/${ARCH})"
case "$ARCH" in
  amd64) GITLEAKS_ARCH=x64 ;;
  arm64) GITLEAKS_ARCH=arm64 ;;
esac
GITLEAKS_TGZ="gitleaks_${GITLEAKS_VERSION}_${OS}_${GITLEAKS_ARCH}.tar.gz"
curl -fsSL -o "$GITLEAKS_TGZ" \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/${GITLEAKS_TGZ}"
curl -fsSL -o gitleaks_checksums.txt \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_checksums.txt"
verify_sha256 "$GITLEAKS_TGZ" gitleaks_checksums.txt
tar -xzf "$GITLEAKS_TGZ" -C "$BIN" gitleaks
chmod +x "$BIN/gitleaks"

# ---- kustomize -------------------------------------------------------------
# Renders k8s/overlays/prod for kubeconform validation (CI + local). Used
# instead of `kubectl kustomize` to keep the toolchain project-local (no
# host kubectl dependency). Release tag form: kustomize/vX.Y.Z; asset
# kustomize_vX.Y.Z_<os>_<arch>.tar.gz.
echo ">>> kustomize ${KUSTOMIZE_VERSION} (${OS}/${ARCH})"
KUSTOMIZE_TGZ="kustomize_v${KUSTOMIZE_VERSION}_${OS}_${ARCH}.tar.gz"
curl -fsSL -o "$KUSTOMIZE_TGZ" \
  "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/${KUSTOMIZE_TGZ}"
curl -fsSL -o kustomize_checksums.txt \
  "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/checksums.txt"
verify_sha256 "$KUSTOMIZE_TGZ" kustomize_checksums.txt
tar -xzf "$KUSTOMIZE_TGZ" -C "$BIN" kustomize
chmod +x "$BIN/kustomize"

# ---- done -----------------------------------------------------------------
echo
echo ">>> installed binaries in ${BIN}:"
ls -la "$BIN"
