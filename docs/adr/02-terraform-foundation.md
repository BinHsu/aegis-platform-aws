# ADR-02: Terraform foundation — state & toolchain

## Status

Accepted.

## Context

Two foundation choices precede any infrastructure. **State locking** — the
conventional S3 remote backend pairs the state bucket with a DynamoDB table for
locking: a second resource to provision, tag, and pay for. **Tooling** — the
repo needs `terraform`, `tflint`, `tfsec`, `kubeconform`, `hadolint`, `jq`,
`kustomize`, `gitleaks`; installing those onto the host (`brew install …`)
drifts versions between contributors and CI and pollutes a reviewer's machine
when they clone to evaluate.

## Decision

**S3 native state locking.** Terraform 1.10 introduced `use_lockfile` — locking
via an S3 conditional write (`PutObject` with `If-None-Match`, the atomic
create-if-absent primitive a lock needs); 1.11 marked it stable and deprecated
the DynamoDB locking arguments, slated for removal upstream. The `bootstrap`
environment creates only the state bucket — no DynamoDB table. Each downstream
backend sets `use_lockfile = true`; the lock lives at `<state-key>.tflock` in
the same bucket. The Terraform binary is pinned to 1.14.8 and `required_version`
to `~> 1.11` to guarantee the feature is present.

**Project-local toolchain.** Every tool lives inside the project.
`scripts/install-tools.sh` fetches pinned versions, verifies each against its
published SHA256, and extracts to `./bin/` (gitignored). The `Makefile`
prepends `./bin/` to `PATH`; `.terraform-version` pins the Terraform binary;
every root module pins `required_version` and provider versions, and
`.terraform.lock.hcl` is committed.

## Consequences

- One fewer resource: the lock is co-located with the state it guards, and
  adopting native locking now avoids a forced migration when DynamoDB locking
  is removed upstream.
- `git clone && make dev-setup` reproduces the exact toolchain — no host
  install, no `sudo`, no drift. CI runs the same `install-tools.sh`, so local
  and CI tool versions match.
- The CI plan jobs run `terraform plan -lock=false`: the read-only plan IAM
  role cannot write the `.tflock` object, and a plan does not mutate state, so
  the lock is unnecessary there. Apply jobs (write role) lock normally.
- One platform gap: `hadolint` has no native darwin/arm64 build and segfaults
  under Rosetta, so it is skipped on Apple Silicon — the Linux CI runner covers
  Dockerfile linting.
- Cost: a bespoke install script to maintain instead of a one-line `brew`.
  Accepted — reviewer reproducibility outweighs it.
