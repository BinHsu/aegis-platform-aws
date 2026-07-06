#!/usr/bin/env bash
# scripts/e2e/negative/assert-require-digest.sh
#
# NEGATIVE assertion for the ADR-10 require-image-digest ClusterPolicy (issue
# #170). Proves that with require-digest in Enforce mode (the golden-path
# harness-local override), a tag-only Pod in an `aegis-*` namespace is REJECTED
# at admission, while a digest-pinned Pod is ADMITTED.
#
# SUBSTRATE-AGNOSTIC: takes the cluster via $KUBECONFIG; runs unchanged on kind
# and k3s. Assumes golden-path.sh has already run (policies applied, $E2E_NS up).
#
# Usage: KUBECONFIG=... ./scripts/e2e/negative/assert-require-digest.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_NS="${E2E_NS:-aegis-e2e}"
TAG_ONLY_POD="$HERE/tag-only-pod.yaml"

# A digest-pinned busybox (immutable index digest) — the POSITIVE control. Same
# image family as the tag-only pod, only the reference form differs, so the test
# isolates exactly the digest-vs-tag axis the policy gates on.
DIGEST_IMAGE="busybox:1.37@sha256:9532d8c39891ca2ecde4d30d7710e01fb739c87a8b9299685c63704296b16028"

echo "==> [require-digest] NEGATIVE: tag-only Pod must be DENIED under Enforce"
if kubectl apply -f "$TAG_ONLY_POD" 2>/tmp/require-digest-deny.err; then
  echo "    FAIL: tag-only Pod was ADMITTED — require-digest is not enforcing."
  kubectl delete -f "$TAG_ONLY_POD" --ignore-not-found >/dev/null 2>&1 || true
  exit 1
fi
# Confirm it was OUR policy that blocked it (not some unrelated apply error).
if ! grep -qi 'require-image-digest\|sha256 digest\|require-digest-pinned-image' /tmp/require-digest-deny.err; then
  echo "    FAIL: Pod was rejected, but not by require-image-digest. Rejection was:"
  cat /tmp/require-digest-deny.err
  exit 1
fi
echo "    OK: tag-only Pod rejected by require-image-digest:"
grep -i 'sha256 digest\|require-image-digest' /tmp/require-digest-deny.err | head -2 | sed 's/^/      /'

echo "==> [require-digest] POSITIVE: digest-pinned Pod must be ADMITTED"
DIGEST_POD="$(mktemp)"
cat >"$DIGEST_POD" <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: digest-pinned-pod
  namespace: $E2E_NS
  labels:
    aegis.binhsu.org/test: require-digest-positive
spec:
  restartPolicy: Never
  containers:
    - name: digest-pinned
      image: $DIGEST_IMAGE
      command: ["sh", "-c", "sleep 3600"]
YAML
if ! kubectl apply -f "$DIGEST_POD"; then
  echo "    FAIL: digest-pinned Pod was DENIED — policy is too strict (false positive)."
  exit 1
fi
echo "    OK: digest-pinned Pod admitted."
kubectl delete -f "$DIGEST_POD" --ignore-not-found >/dev/null 2>&1 || true

echo "==> require-digest negative assertion PASSED (deny tag-only, admit digest)."
