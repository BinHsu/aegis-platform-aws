#!/usr/bin/env bash
# scripts/e2e/b2/local-registry.sh
#
# B2 (epic #167 / ADR-26) — local image registry for the kind lane. SOURCEABLE
# helper shared by the local runner (scripts/e2e/local/kind-b2-run.sh) and the CI
# workflow (.github/workflows/e2e-golden-path.yml), so the registry wiring lives
# in exactly one place.
#
# WHAT / WHY: a `registry:2` container (kind's documented local-registry pattern)
# stands in for ECR on kind. The kind cluster's containerd has the registry
# host-config directory enabled (scripts/e2e/kind/kind-calico.yaml ::
# containerdConfigPatches -> config_path = /etc/containerd/certs.d); registry_up
# writes a per-node hosts.toml mapping `localhost:5000` to this container over
# the kind docker network, so an in-cluster image ref
# `localhost:5000/<repo>@sha256:<digest>` pulls from it. hosts.toml (NOT the
# legacy containerd `registry.mirrors` table) because containerd 2.x REMOVED that
# table — this pattern works on containerd 1.7 (CI's v1.32.11 node image) and
# 2.x (newer local node images) alike.
#
# DIGEST PRESERVATION: we SEED with `crane copy`, which copies the source
# manifest byte-for-byte — the destination digest EQUALS the source digest
# (content-addressed identity). That is what lets the fixture commit a STABLE
# `@sha256:` pin (fixtures/sample-deploy) that resolves against the local
# registry. `docker push` would re-digest (recompress / drop the multi-arch
# index), breaking the committed pin — hence crane, not docker.
#
# Functions:
#   registry_up   <kind-cluster-name>          — start registry:2, join kind net,
#                                                write per-node hosts.toml mirror
#                                                (nodes must exist — run AFTER
#                                                `kind create cluster`)
#   registry_seed <src-ref@sha256:..> <dstRepo> — crane copy, preserving digest
#   registry_down                               — remove the registry container
set -euo pipefail

REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"
# registry:2 pinned by digest (harness-local supply-chain hygiene). 2.8.3.
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2.8.3}"
# crane (google/go-containerregistry) — pinned. Fetched to a temp bin if absent
# (non-host-mutating: nothing installed globally).
CRANE_VERSION="${CRANE_VERSION:-v0.20.2}"
CRANE=""

# Resolve a crane binary: prefer PATH, else download the pinned release to a
# throwaway dir. Sets $CRANE.
ensure_crane() {
  if command -v crane >/dev/null 2>&1; then CRANE="$(command -v crane)"; return; fi
  if [ -n "$CRANE" ] && [ -x "$CRANE" ]; then return; fi
  local os arch asset dir
  os="$(uname -s)"; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) echo "ensure_crane: unsupported arch '$arch'" >&2; return 1 ;;
  esac
  asset="go-containerregistry_${os}_${arch}.tar.gz"
  dir="$(mktemp -d)"
  echo "==> [registry] fetching crane ${CRANE_VERSION} (${asset})"
  curl -sSfL "https://github.com/google/go-containerregistry/releases/download/${CRANE_VERSION}/${asset}" \
    | tar -xz -C "$dir" crane
  CRANE="$dir/crane"
  chmod +x "$CRANE"
  "$CRANE" version || true
}

# Start registry:2 (idempotent), attach it to the kind docker network, and write
# the per-node containerd hosts.toml so `localhost:$REGISTRY_PORT` resolves to it
# in-cluster. Must run AFTER `kind create cluster` (it writes into the nodes).
registry_up() {
  local cluster="${1:?registry_up needs the kind cluster name}"
  local net="kind"
  if [ "$(docker inspect -f '{{.State.Running}}' "$REGISTRY_NAME" 2>/dev/null || true)" != "true" ]; then
    echo "==> [registry] starting ${REGISTRY_NAME} (${REGISTRY_IMAGE}) on 127.0.0.1:${REGISTRY_PORT}"
    docker run -d --restart=always \
      -p "127.0.0.1:${REGISTRY_PORT}:5000" \
      --name "$REGISTRY_NAME" \
      "$REGISTRY_IMAGE" >/dev/null
  else
    echo "==> [registry] ${REGISTRY_NAME} already running"
  fi
  # Join the kind network (idempotent — ignore "already exists").
  docker network connect "$net" "$REGISTRY_NAME" >/dev/null 2>&1 || true
  echo "    ${REGISTRY_NAME} on docker network '${net}', mirror target http://${REGISTRY_NAME}:5000"

  # Per-node hosts.toml: containerd resolves `localhost:$REGISTRY_PORT` via
  # config_path (/etc/containerd/certs.d, enabled in kind-calico.yaml) to the
  # registry container over the kind network. `skip_verify` because the harness
  # registry is plain HTTP. containerd picks hosts.toml changes up per-pull —
  # no containerd restart needed (kind's documented pattern).
  local hosts_dir="/etc/containerd/certs.d/localhost:${REGISTRY_PORT}"
  local node
  for node in $(kind get nodes --name "$cluster"); do
    echo "    wiring mirror on node ${node} (${hosts_dir}/hosts.toml)"
    docker exec "$node" mkdir -p "$hosts_dir"
    printf '[host."http://%s:5000"]\n  skip_verify = true\n' "$REGISTRY_NAME" \
      | docker exec -i "$node" tee "${hosts_dir}/hosts.toml" >/dev/null
  done
}

# crane copy a digest-pinned source image into localhost:<port>/<dstRepo>,
# preserving the manifest digest. HTTP (insecure) — the harness registry is plain.
registry_seed() {
  local src="${1:?registry_seed needs a src image ref (…@sha256:…)}"
  local dst_repo="${2:?registry_seed needs a destination repo name}"
  ensure_crane
  local dst="localhost:${REGISTRY_PORT}/${dst_repo}"
  echo "==> [registry] crane copy ${src} -> ${dst} (digest preserved)"
  "$CRANE" copy --insecure "$src" "$dst"
  # Echo the resulting digest for evidence — MUST equal the source digest.
  "$CRANE" digest --insecure "$dst" | sed 's/^/    seeded digest: /'
}

registry_down() {
  docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
}
