# Security Policy

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Use [GitHub private vulnerability reporting](https://github.com/BinHsu/aegis-platform-aws/security/advisories/new).
The maintainer will acknowledge the report within 5 business days and provide an
estimated resolution timeline.

## Scope

`aegis-platform-aws` is a **portfolio / demonstration repo**. It provisions
non-production AWS infrastructure used for architectural validation and
take-home interview work. There is no production user data, no SLA, and no
regulated data category in scope.

Vulnerabilities of interest:

- Terraform IaC that provisions overly-permissive IAM roles or policies.
- Secrets or account IDs committed to the repository.
- Supply-chain issues in pinned provider or Helm chart versions.
- CI workflow permissions that allow privilege escalation.

Out of scope: denial-of-service against ephemeral AWS infrastructure, issues
that require physical access, or findings in third-party dependencies with no
exploitable path through this repo's code.

## IaC security gates already in CI

Every pull request runs the following automated checks before merge is allowed:

| Tool | What it checks |
|------|---------------|
| `trivy` | Terraform misconfigurations (HIGH/CRITICAL block merge) |
| `tflint` | Terraform best-practice lint |
| `gitleaks` | Secret / credential leakage scan on every commit |
| GitHub Dependabot | Provider and action version drift |

These gates run in `infra-plan.yml` and results are posted as PR comments.

## Supported versions

Only the current `main` branch is maintained. No backport policy applies to a
portfolio repo.
