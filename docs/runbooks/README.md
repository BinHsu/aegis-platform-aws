# Runbooks

Operational runbooks for the aegis-platform-aws platform tier.

| File | Purpose |
|---|---|
| [`2026-06-20-dual-region-full-verification.md`](2026-06-20-dual-region-full-verification.md) | Consolidated dual-region (staging → prod) architectural and functional verification plan and execution record for the Phase 2 GHCR/Graviton bring-up. |
| [`observability-queries.md`](observability-queries.md) | PromQL (Mimir) and LogQL (Loki) query reference for golden signals, cluster/node USE metrics, and Alloy pipeline health. |
| [`bootstrap-state-migration-90.md`](bootstrap-state-migration-90.md) | One-time operator-attended migration of the pre-#90 local bootstrap state into the per-account Terraform workspace layout (`terraform.tfstate.d/<ENV>/`). Local-file only — no `terraform apply`, read-only `plan` verification, per-step rollback. |
