#!/usr/bin/env bash
# scripts/ttl-reap-scan.sh — Layer-3 TTL reaper scan (incident 2026-06-06; A11).
#
# Generalises the reaper beyond EKS (the original incident driver) to the other
# common billable leaks. Over-TTL EKS clusters become auto-destroy candidates
# (honouring a ttl-exempt/keep tag); NAT gateways, RDS instances and load
# balancers are ALERT-ONLY (age-based) — they are flagged for a human, never
# auto-destroyed, because cross-type auto-teardown has no safe generic path.
#
# Emits `found`, `eks_list`, `other_list` to $GITHUB_OUTPUT (stdout if unset).
# Fully best-effort: every AWS call is guarded, the script never exits non-zero.
#
# Env: TTL_HOURS (default 8). SCAN_REGIONS (optional, space-separated) overrides the
# region list — the multi-account ttl-reaper matrix passes one region per job from
# accounts.json (the accounts-dimension ADR's single source of topology).
# Arg 1: regions SoT json (default regions.auto.tfvars.json; ignored when SCAN_REGIONS set).
set -uo pipefail

TTL_HOURS="${TTL_HOURS:-8}"
SOT="${1:-regions.auto.tfvars.json}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

if [ -n "${SCAN_REGIONS:-}" ]; then
  regions="$SCAN_REGIONS"
else
  regions=$(jq -r '[.regions|to_entries[]|select(.value.enabled)|.key]|.[]' "$SOT" 2>/dev/null || true)
fi
now=$(date -u +%s)
ttl=$(( TTL_HOURS * 3600 ))

# GNU date on the CI runner parses ISO8601; returns 0 (→ never over-TTL) on failure.
epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }
over()  { local e; e=$(epoch "$1"); [ "$e" -gt 0 ] && [ "$(( now - e ))" -ge "$ttl" ]; }
agehrs() { local e; e=$(epoch "$1"); echo $(( (now - e) / 3600 )); }

eks_list=""
other_list=""

for r in $regions; do
  # --- EKS clusters: auto-destroy candidates, honour ttl-exempt/keep ---
  for c in $(aws eks list-clusters --region "$r" --query 'clusters[]' --output text 2>/dev/null || true); do
    created=$(aws eks describe-cluster --name "$c" --region "$r" --query 'cluster.createdAt' --output text 2>/dev/null || true)
    [ -z "$created" ] && continue
    ex=$(aws eks describe-cluster --name "$c" --region "$r" --query 'cluster.tags."ttl-exempt" || cluster.tags.keep' --output text 2>/dev/null || echo None)
    [ "$ex" = "true" ] && continue
    if over "$created"; then eks_list="${eks_list}${r}/eks/${c} ($(agehrs "$created")h)\n"; fi
  done
  # --- NAT gateways: alert-only ---
  while read -r id created; do
    [ -z "$id" ] && continue
    if over "$created"; then other_list="${other_list}${r}/nat/${id} ($(agehrs "$created")h)\n"; fi
  done <<EOF
$(aws ec2 describe-nat-gateways --region "$r" --filter Name=state,Values=available --query 'NatGateways[].[NatGatewayId,CreateTime]' --output text 2>/dev/null || true)
EOF
  # --- RDS instances: alert-only ---
  while read -r id created; do
    [ -z "$id" ] && continue
    if over "$created"; then other_list="${other_list}${r}/rds/${id} ($(agehrs "$created")h)\n"; fi
  done <<EOF
$(aws rds describe-db-instances --region "$r" --query 'DBInstances[].[DBInstanceIdentifier,InstanceCreateTime]' --output text 2>/dev/null || true)
EOF
  # --- ELBv2 load balancers: alert-only ---
  while read -r arn created; do
    [ -z "$arn" ] && continue
    if over "$created"; then other_list="${other_list}${r}/elb/${arn##*/} ($(agehrs "$created")h)\n"; fi
  done <<EOF
$(aws elbv2 describe-load-balancers --region "$r" --query 'LoadBalancers[].[LoadBalancerArn,CreatedTime]' --output text 2>/dev/null || true)
EOF
done

found=false
[ -n "${eks_list}${other_list}" ] && found=true
{
  echo "found=${found}"
  echo "eks_list<<REAP_EOF"; printf '%b' "$eks_list"; echo "REAP_EOF"
  echo "other_list<<REAP_EOF"; printf '%b' "$other_list"; echo "REAP_EOF"
} >> "$OUT"
[ "$found" = true ] && echo "::warning::ttl-reaper found over-TTL resource(s) — see job log/issue"
exit 0
