#!/usr/bin/env bash
# Pre-teardown — remove the in-cluster resources that own AWS objects
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
#   Usage:  scripts/dr/pre-teardown.sh <region>
#
# Idempotent: if the cluster, the Application, or the Ingress is already gone,
# the relevant step is skipped — safe to re-run.

set -euo pipefail

REGION="${1:?usage: pre-teardown.sh <region>}"
CLUSTER="aegis-stateless-${REGION}"

if ! aws eks describe-cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  echo "pre-teardown: cluster $CLUSTER not found — nothing to clean, skipping."
  exit 0
fi

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" >/dev/null

echo "pre-teardown: removing the ArgoCD Application so it stops re-syncing greeter..."
kubectl delete application aegis-greeter -n argocd --ignore-not-found --timeout=60s 2>/dev/null || true

echo "pre-teardown: deleting the greeter Ingress — the ALB controller then deletes its ALB..."
kubectl delete ingress --all -n greeter --ignore-not-found --timeout=120s 2>/dev/null || true

echo "pre-teardown: waiting (up to 5 min) for the ALB controller to delete the greeter ALB..."
deadline=$(( $(date +%s) + 300 ))
while AWS_PAGER='' aws elbv2 describe-load-balancers --region "$REGION" \
        --query "LoadBalancers[?contains(LoadBalancerName, 'k8s-greeter')].LoadBalancerArn" \
        --output text 2>/dev/null | grep -q .; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "pre-teardown: WARNING — a greeter ALB is still present after 5 min." >&2
    echo "  terraform destroy may stall on a DependencyViolation; if so, delete" >&2
    echo "  the ALB manually (aws elbv2 delete-load-balancer) and re-run." >&2
    break
  fi
  sleep 15
done
echo "pre-teardown: done — safe to terraform destroy."
