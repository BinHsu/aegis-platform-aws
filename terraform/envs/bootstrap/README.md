# bootstrap env

Creates the S3 bucket that the `platform/` and `regional/` envs use as their remote backend. **No DynamoDB lock table** — TF ≥ 1.11 supports native S3 conditional-write locking via `use_lockfile = true` in each downstream backend block (DynamoDB-based locking is deprecated upstream and will be removed in a future minor version).

## Apply once, never destroy

This env's own state is **local** (gitignored `terraform.tfstate`) by design: migrating bootstrap state into the very bucket it provisions would create a chicken-and-egg cycle. Bootstrap is intentionally one-shot.

The bucket has `lifecycle { prevent_destroy = true }`. To remove it, an operator must edit that block first — guarding against accidental `terraform destroy`.

## Usage

```bash
make bootstrap   # local-state apply (reads regions.auto.tfvars.json for platform_region)
```

After apply, the Makefile reads the `backend_hcl` output and writes a `backend.hcl` file at repo root (gitignored). Downstream envs then run `terraform init -backend-config=$(ROOT)/backend.hcl`.

## What it creates

| Resource | Why |
|---|---|
| S3 bucket `aegis-stateless-tfstate-${account_id}` | Remote state for platform + regional. Versioned + SSE-KMS (`alias/aws/s3`) + Block Public Access. Lock files live at `<state_key>.tflock` in the same bucket (TF ≥ 1.11 native locking via PutObject IfNoneMatch). |

## Production hardening (out of scope, documented in tradeoffs)

- Customer-managed KMS key (granular key policy + cross-account access) instead of `aws/s3`.
- S3 Object Lock for compliance write-once semantics.
- Cross-region replication of the state bucket for region-failure resilience.
