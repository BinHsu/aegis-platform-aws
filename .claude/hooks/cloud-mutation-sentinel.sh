#!/usr/bin/env bash
# PreToolUse(Bash) — Layer-2 prevention (incident 2026-06-06).
#
# Records a sentinel when the agent runs a cloud-MUTATING command, so the Stop
# hook (cloud-mutation-stop-gate.sh) can block the session from ending with an
# unreconciled mutation. This hook NEVER blocks the tool call itself — it only
# records. The agent clears the sentinel (rm) after verifying the run reached
# green / the stack was torn down.
set -euo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -z "$cmd" ] && exit 0

here="$(cd "$(dirname "$0")/.." && pwd)"
sentinel="$here/.cloud-mutation-open"

# Cloud-mutating patterns: apply/destroy of real infra (terraform, the apply/
# destroy CI workflows, or the make cloud-up/down path).
if printf '%s' "$cmd" | grep -Eq \
  '(terraform[[:space:]]+(apply|destroy))|(gh[[:space:]]+workflow[[:space:]]+run[^|]*(infra-apply|operation=(apply|destroy)|cloud-(apply|destroy)))|(make[[:space:]]+cloud-(up|down))'; then
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\t%s\n' "$ts" "$cmd" >> "$sentinel"
fi
exit 0
