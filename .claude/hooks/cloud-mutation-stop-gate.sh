#!/usr/bin/env bash
# Stop — Layer-2 prevention (incident 2026-06-06).
#
# Blocks the session from ending while a cloud mutation is unreconciled (a
# sentinel from cloud-mutation-sentinel.sh is present), UNLESS a human override
# (.abandon-ok) exists. This is a loud nudge, not an infinite wall: it blocks
# once per stop attempt; on a re-stop (stop_hook_active) it lets through to avoid
# trapping an unattended session. The HARD backstop for the unattended case is
# Layer 3 (the TTL reaper) — this layer only covers "a human is present, about
# to walk away".
#
# Exits:
#   - drive the run to green / tear the stack down, then: rm .cloud-mutation-open
#   - or, explicit human abandon: touch .abandon-ok
set -euo pipefail

input=$(cat)
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
[ "$active" = "true" ] && exit 0 # already nudged once → don't trap

here="$(cd "$(dirname "$0")/.." && pwd)"
sentinel="$here/.cloud-mutation-open"
override="$here/.abandon-ok"

if [ -f "$sentinel" ] && [ ! -f "$override" ]; then
  pending=$(tr '\n' ';' <"$sentinel" 2>/dev/null || true)
  reason="OPEN cloud mutation(s) not reconciled: ${pending} | Resolve: drive CI to green or verify teardown, then 'rm ${sentinel}'. Override (explicit human abandon): 'touch ${override}'. (Layer-3 TTL reaper is the unattended backstop.)"
  jq -n --arg r "$reason" '{decision:"block", reason:$r}'
  exit 0
fi
exit 0
