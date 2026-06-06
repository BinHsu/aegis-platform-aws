#!/usr/bin/env bash
# scripts/install-tools.sh
#
# Fetches pinned dev tools into a project-local bin directory (default ./bin/).
# Per "Host isolation discipline": this script never touches /usr/local, never
# touches ~/.terraform.d/plugins, and never uses sudo. A forker can clone +
# `make dev-setup` without conflicting with their existing toolchain.
#
# Per inherited safety guardrail (h): each binary is fetched from its upstream
# GitHub release and SHA256-verified against the release's published checksums
# file before being placed in $BIN. Hardening path (not implemented for this
# scope): cosign / GPG signature verification of the checksums file itself;
# see docs/tradeoffs.md.
#
# aegis-platform-aws is the platform tier — Terraform + CI only. It carries no
# Kubernetes manifests (those live in the per-workload deploy repos) and no
# Dockerfile, so the toolchain is tflint / trivy / jq / gitleaks. It does not
# install kubeconform / kustomize (manifest validation belongs in the deploy
# repos) or hadolint (no Dockerfile here).
#
# Usage: ./scripts/install-tools.sh [BIN_DIR]
#   defaults to $PWD/bin

set -euo pipefail

BIN="${1:-$PWD/bin}"
mkdir -p "$BIN"

# ---- pinned versions -------------------------------------------------------
TFLINT_VERSION=v0.53.0
TRIVY_VERSION=v0.71.0 # IaC misconfig scanner; successor to the EOL tfsec
JQ_VERSION=1.7.1
GITLEAKS_VERSION=8.24.3

# ---- OS / arch detection ---------------------------------------------------
OS=$(uname -s | tr '[:upper:]' '[:lower:]')   # darwin | linux
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64)  ARCH=amd64 ;;
  arm64|aarch64) ARCH=arm64 ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac

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

# ---- trivy (IaC misconfig scanner; successor to the EOL tfsec) --------------
# tfsec is end-of-life and its HCL parser rejects Terraform 1.5 `check` blocks
# (incident 2026-06-06). trivy is the maintained successor and parses modern TF.
# Asset naming differs: trivy_<ver>_macOS-ARM64.tar.gz / trivy_<ver>_Linux-64bit.tar.gz.
echo ">>> trivy ${TRIVY_VERSION} (${OS}/${ARCH})"
case "$OS" in
  darwin) TRIVY_OS=macOS ;;
  linux) TRIVY_OS=Linux ;;
esac
case "$ARCH" in
  amd64) TRIVY_ARCH=64bit ;;
  arm64) TRIVY_ARCH=ARM64 ;;
esac
TRIVY_TGZ="trivy_${TRIVY_VERSION#v}_${TRIVY_OS}-${TRIVY_ARCH}.tar.gz"
curl -fsSL -o "$TRIVY_TGZ" \
  "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}/${TRIVY_TGZ}"
curl -fsSL -o trivy_checksums.txt \
  "https://github.com/aquasecurity/trivy/releases/download/${TRIVY_VERSION}/trivy_${TRIVY_VERSION#v}_checksums.txt"
verify_sha256 "$TRIVY_TGZ" trivy_checksums.txt
tar -xzf "$TRIVY_TGZ" -C "$BIN" trivy
chmod +x "$BIN/trivy"

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
# Secret scanner — used by the pre-commit hook (.githooks/pre-commit). The
# infra-plan CI job pins the same version. Asset naming:
# gitleaks_<ver>_<os>_<arch>.tar.gz, arch token is x64 (not amd64) / arm64.
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

# ---- done -----------------------------------------------------------------
echo
echo ">>> installed binaries in ${BIN}:"
ls -la "$BIN"
