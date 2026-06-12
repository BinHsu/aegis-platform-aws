#!/usr/bin/env bash
# Pre-destroy — remove the in-cluster resources that own AWS objects
# Terraform does not track, so `terraform destroy` of the VPC does not stall.
#
# The AWS Load Balancer Controller creates an ALB (with ENIs + public IPs) in
# response to the greeter Ingress. That ALB is not in Terraform state; if it
# outlives the controller, its ENIs hold the subnets and its public IPs hold
# the internet gateway, and `terraform destroy` fails with DependencyViolation.
#
# Fix: while the controller is still running, drop the ArgoCD Application (so
# it stops re-syncing the Ingress) and delete the Ingress; the controller then
# deletes the ALB. Wait for that, then return so `terraform destroy` can run.
#
#   Usage:  scripts/dr/pre-destroy.sh <region> [cluster-name]
#
#   <region>       : AWS region (required)
#   [cluster-name] : EKS cluster name (optional; defaults to aegis-platform-<region>)
#                    Pass explicitly when callers already have the terraform output
#                    to avoid the previous "aegis-platform-aws-<region>" misguess.
#
# Idempotent: if the cluster, the Application, or the Ingress is already gone,
# the relevant step is skipped — safe to re-run.

set -euo pipefail

REGION="${1:?usage: pre-destroy.sh <region> [cluster-name]}"
# Derive the cluster name from the caller when available (the terraform output
# is the authoritative source); fall back to the canonical naming convention
# aegis-platform-<region> (locals.tf: cluster_name = "aegis-platform-${var.region}").
CLUSTER="${2:-aegis-platform-${REGION}}"

if ! aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  echo "pre-destroy: cluster $CLUSTER not found — nothing to clean, skipping."
  exit 0
fi

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

echo "pre-destroy: removing the ArgoCD Application so it stops re-syncing greeter..."
kubectl delete application aegis-greeter -n argocd --ignore-not-found --timeout=60s 2>/dev/null || true

echo "pre-destroy: deleting the greeter Ingress — the ALB controller then deletes its ALB..."
kubectl delete ingress --all -n greeter --ignore-not-found --timeout=120s 2>/dev/null || true

# Resolve the cluster's VPC so the ALB-wait poll is name-agnostic.
# The ALB is named k8s-<namespace-hash>-* (e.g. k8s-aegisgre-* for namespace
# aegis-greeter) — the exact suffix is not predictable, so scope by VPC instead.
VPC="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo '')"

echo "pre-destroy: waiting (up to 5 min) for the ALB controller to delete the greeter ALB..."
deadline=$(( $(date +%s) + 300 ))
while true; do
  if [ -z "$VPC" ] || [ "$VPC" = "None" ]; then
    break  # VPC gone — no ELBv2 can remain
  fi
  remaining="$(AWS_PAGER='' aws elbv2 describe-load-balancers --region "$REGION" \
                 --query "LoadBalancers[?VpcId=='${VPC}'].LoadBalancerArn" \
                 --output text 2>/dev/null || true)"
  [ -z "$remaining" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "pre-destroy: WARNING — an ALB in VPC ${VPC} is still present after 5 min." >&2
    echo "  terraform destroy may stall on a DependencyViolation; if so, delete" >&2
    echo "  the ALB manually (aws elbv2 delete-load-balancer) and re-run." >&2
    break
  fi
  sleep 15
done
echo "pre-destroy: done — safe to terraform destroy."
