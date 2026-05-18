# GitHub branch protection on main — the gate that makes CI-driven apply
# safe. Without these rules, anyone with write access could push directly
# to main and trigger an apply; with them, every change is forced through
# PR + status checks + linear history.
#
# Note: branch protection on private repos requires GitHub Pro or higher.
# On free private repos, this resource will fail to apply — adjust based
# on your plan.

# Signed commits are not enforced — it would block any unsigned local
# commit and require every contributor to configure GPG/SSH signing.
# Documented in docs/tradeoffs.md as a hardening option for a team that
# has commit signing set up.
#tfsec:ignore:github-branch_protections-require_signed_commits
resource "github_branch_protection" "main" {
  # GitHub gates branch protection on a private repo behind Pro. Default
  # off (var.enable_branch_protection = false) so a free private repo
  # applies; flip it true once the repo is public or the account is on
  # Pro. See docs/tradeoffs.md.
  count = var.enable_branch_protection ? 1 : 0

  repository_id = "aegis-stateless"
  pattern       = "main"

  # Status check gate — infra-plan workflow's summary job must pass before
  # merge. The summary job aggregates fmt + validate + lint + sec +
  # plan-platform + plan-regional matrix.
  required_status_checks {
    strict = false # "Require branches to be up to date" — off for solo speed
    contexts = [
      "infra-plan / summary",
    ]
  }

  # Linear history forbids merge commits — keeps state-apply correlation
  # straightforward (1 commit = 1 apply trigger).
  required_linear_history = true

  # Force-push or branch deletion on main would orphan the apply history.
  allows_force_pushes = false
  allows_deletions    = false

  # `required_pull_request_reviews` intentionally omitted for the solo-
  # contributor take-home scenario (Bin cannot approve own PRs on GitHub
  # without a second account). Status checks + linear history are the
  # gate. For multi-contributor production, re-add:
  #
  # required_pull_request_reviews {
  #   required_approving_review_count = 1
  #   dismiss_stale_reviews            = true
  #   require_code_owner_reviews       = false
  # }

  # Admins bypass for emergency operator intervention; documented escape
  # hatch. Audit trail in GH log captures any bypass.
  enforce_admins = false
}
