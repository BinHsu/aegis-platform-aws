# DNS-layer failover — evidence

Companion to [`DR_REPORT.md`](DR_REPORT.md). The DR drill proved a region can be
rebuilt from zero and that the surviving region keeps serving — *redundancy*.
This is the other half: that Route 53 **routes away** from a region whose ALB
is unhealthy — the cross-region failover *cutover*.

## Setup

`greeter.aegis-stateless.test` is a Route 53 latency record set — one alias per
region, each pointing at that region's ALB with `evaluate_target_health = true`
(created by external-dns from the greeter Ingress annotations). A query returns
the lowest-latency region whose ALB is healthy.

Queries were run from inside each EKS cluster (`dig @<zone-nameserver> ...`):
AWS does not transparently intercept DNS, so these reach Route 53's
authoritative servers — the responses carry the `aa` (authoritative) flag.

## 1. Both regions healthy — latency routing

The same hostname, queried from each region, resolves to that region's own ALB:

| Query from | `greeter.aegis-stateless.test` resolves to |
|---|---|
| eu-central-1 cluster | `3.75.163.30`, `18.156.170.81`, `52.58.104.143` — the eu-central-1 ALB |
| eu-west-1 cluster | `63.35.57.135`, `34.251.58.119`, `108.132.171.134` — the eu-west-1 ALB |

## 2. eu-central-1 ALB unhealthy — failover

The eu-central-1 greeter Deployment was scaled to 0; its ALB lost every healthy
target (`draining`). The **same query, still from the eu-central-1 cluster**,
then resolved to the **eu-west-1** ALB:

```
dig(eu-central-1 cluster)  greeter.aegis-stateless.test  A
  ->  63.35.57.135   108.132.171.134   34.251.58.119      [the eu-west-1 ALB]
```

Route 53's `evaluate_target_health` saw eu-central-1's ALB unhealthy, stopped
returning its latency record, and the query failed over to the only healthy
region. Not "a query finds its own region" — a query whose own region is down
is steered to the survivor. The record TTL is 60 s, which bounds how fast a
downstream resolver picks up the change. eu-central-1 was then restored.
