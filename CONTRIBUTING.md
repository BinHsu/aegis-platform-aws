# Contributing to aegis-platform-aws

`aegis-platform-aws` is the platform tier of the Aegis portfolio — EKS substrate,
per-cluster ArgoCD, Crossplane XRDs, and observability. Changes here affect every
workload that runs on the platform, so the bar for correctness is high.

---

## Fork model

This repo uses the **fork + pull-request** model.

1. Fork `BinHsu/aegis-platform-aws` on GitHub.
2. Clone your fork locally.
3. Set up the toolchain (see [Dev setup](#dev-setup)).
4. Create a feature branch (see [Branch naming](#branch-naming)).
5. Push and open a PR against `main` of the upstream repo.
6. Address review feedback; CI must be green before merge.

---

## Dev setup

All project-local toolchain binaries install into `./bin/` — nothing writes to the
host outside this repo.

```bash
make dev-setup          # installs terraform, tflint, trivy, gitleaks, jq into ./bin/
source .envrc           # or: export PATH="$(pwd)/bin:$PATH"
make fmt                # terraform fmt -recursive
make lint               # tflint
make sec                # trivy + gitleaks
```

**Minimum requirements (host-provided):**

| Tool | Minimum version |
|------|----------------|
| `terraform` | 1.11 (`.terraform-version` pins 1.14.8 for tfenv/tenv) |
| `make` | any |
| `bash` | 4+ |
| `aws` CLI | 2+ |
| `kubectl` | 1.28+ |
| `gh` (GitHub CLI) | 2+ |

The CI pipeline (`infra-plan.yml`) mirrors this check sequence: fmt → validate →
lint → security scan → plan.

---

## Branch naming

| Change type | Prefix |
|-------------|--------|
| New feature | `feat/` |
| Bug fix | `fix/` |
| Documentation | `docs/` |
| Refactor (no behaviour change) | `refactor/` |
| Chore / tooling / CI | `chore/` |
| Workstream milestone | `ws<N>/` |

Examples: `feat/eks-pod-identity`, `fix/vpc-sg-teardown`, `docs/adr-22`.

---

## Pull request checklist

Before opening a PR, confirm:

- [ ] `make fmt` — no diff after run.
- [ ] `make lint` — zero errors.
- [ ] `make sec` — trivy + gitleaks clean (no new HIGH/CRITICAL findings without a documented exception).
- [ ] `terraform validate` passes in every changed env (`bootstrap`, `platform`, `regional`).
- [ ] If the change adds a Terraform resource: confirm teardown via `terraform destroy` or document why it is irreversible.
- [ ] If the change touches IAM: confirm least-privilege and that no wildcard `*` action is added without justification.
- [ ] If the change is a new architectural decision: an ADR is drafted (see [ADR process](#adr-process)).
- [ ] PR title follows Conventional Commits: `type(scope): short description`.
- [ ] No AWS account IDs, secrets, or credential material appear in any committed file.

---

## ADR process

All significant design decisions are recorded as Architecture Decision Records in
[`docs/adr/`](docs/adr/README.md).

1. Copy the template from an existing ADR (the header block: Status, Context, Decision, Consequences).
2. Name the file `docs/adr/<NN>-<slug>.md` where `NN` is the next available number.
3. Set **Status: Proposed**.
4. Open a PR. Discussion on the ADR happens in the PR review.
5. On merge, update status to **Accepted**.
6. If a later decision supersedes an ADR, update the older record's status to **Superseded by ADR-NN**.

The index at [`docs/adr/README.md`](docs/adr/README.md) lists all ADRs with a
reading-order guide per audience.

---

## Commit style

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
type(scope): short imperative description

Optional longer body. Explain the *why*, not the *what*.
```

Types: `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`, `test`.

---

## Security issues

Do **not** open a public issue for security vulnerabilities. Use
[GitHub private vulnerability reporting](https://github.com/BinHsu/aegis-platform-aws/security/advisories/new)
or see [`SECURITY.md`](SECURITY.md).
