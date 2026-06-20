#!/usr/bin/env bash
# Pre-destroy — remove the in-cluster resources that own AWS objects
# Terraform does not track, so `terraform destroy` of the VPC does not stall.
#
# The AWS Load Balancer Controller creates an ALB/NLB (with ENIs + public IPs)
# in response to an Ingress OR a type=LoadBalancer Service. Those LBs are not in
# Terraform state; if one outlives the controller, its ENIs hold the subnets and
# its public IPs hold the internet gateway, and `terraform destroy` fails with
# DependencyViolation (VPC-stuck).
#
# Fix (ordered): while the controller is still running,
#   1. delete ALL ArgoCD Applications so nothing re-syncs an Ingress/Service;
#   2. delete ALL Ingresses and ALL type=LoadBalancer Services cluster-wide —
#      the controller then deletes their ALBs/NLBs;
#   3. wait until no ELBv2 remains in the cluster's VPC, then return so
#      `terraform destroy` can run.
# Scoped by VPC so it is name-agnostic across workloads (greeter, aegis-core, …).
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

# Stop ArgoCD re-syncing first — otherwise it recreates any Ingress/Service we
# delete below before the controller can reap the AWS object. Delete ALL
# Applications, not just greeter: any workload (aegis-core, future onboards) may
# own an Ingress or a Service that fronts an ALB/NLB.
echo "pre-destroy: removing ALL ArgoCD Applications so nothing re-syncs an Ingress/Service..."
kubectl delete applications --all -n argocd --ignore-not-found --timeout=120s 2>/dev/null || true
# Belt-and-braces for the known greeter app name in case the bulk delete is denied
# by a finalizer/RBAC edge — idempotent.
kubectl delete application aegis-greeter -n argocd --ignore-not-found --timeout=60s 2>/dev/null || true

echo "pre-destroy: deleting all Ingresses — the ALB controller then deletes their ALBs..."
kubectl delete ingress --all --all-namespaces --ignore-not-found --timeout=120s 2>/dev/null || true

# (a) LoadBalancer-type Services own an ALB/NLB + ENIs the same way an Ingress
# does, and they are NOT covered by the Ingress delete above. Delete every
# Service of type LoadBalancer cluster-wide so the controller reaps the backing
# LB before terraform deletes the VPC (orphan LB ENIs → DependencyViolation).
echo "pre-destroy: deleting all type=LoadBalancer Services so their LBs are reaped..."
kubectl get svc --all-namespaces \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
  2>/dev/null | while read -r ns name; do
    [ -z "$ns" ] && continue
    echo "  pre-destroy: deleting LoadBalancer Service ${ns}/${name}"
    kubectl delete svc "$name" -n "$ns" --ignore-not-found --timeout=120s 2>/dev/null || true
  done

# Resolve the cluster's VPC so the ALB-wait poll is name-agnostic.
# The ALB is named k8s-<namespace-hash>-* (e.g. k8s-aegisgre-* for namespace
# aegis-greeter) — the exact suffix is not predictable, so scope by VPC instead.
VPC="$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
        --query 'cluster.resourcesVpcConfig.vpcId' --output text 2>/dev/null || echo '')"

echo "pre-destroy: waiting (up to 5 min) for the controller to delete every ELBv2 in the VPC..."
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
