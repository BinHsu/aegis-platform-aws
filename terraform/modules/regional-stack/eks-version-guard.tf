# EKS version cost guard (incident 2026-06-06).
#
# EKS bills a +$0.50/hr extended-support surcharge ON TOP of the $0.10/hr base
# once a control-plane version leaves standard support — a 6x multiplier that
# an apply-time estimate (which assumes the $0.10 base) does not see. A
# hardcoded `cluster_version = "1.30"` whose standard support ended 2025-07-23
# silently produced extended-support clusters and drove a budget breach.
#
# Design (per postmortem 2026-06-06, §7): the version stays an EXPLICIT,
# human-bumped pin (var.cluster_version) — we do NOT auto-resolve to "latest",
# because in a long-lived cluster that would let a routine apply silently
# trigger a control-plane upgrade (deprecated-API removal, addon incompat) =
# outage. Instead, a `check` block emits a WARNING (non-blocking — it does not
# wedge an emergency apply) on every plan/apply, LOCAL and CI, when the pinned
# version is aging out of standard support. Detection is automated; the upgrade
# itself stays a deliberate human decision. The CI pipeline turns this warning
# into a required-approval gate (see .github/workflows/infra-apply.yml).
#
# Implementation notes (both verified the hard way, 2026-06-06):
#   - `cluster_versions_only` is an OUTPUT (list of version strings), NOT a
#     server-side filter, so we fetch all versions and match in HCL.
#   - `plantimestamp()` (NOT `timestamp()`) is known at plan time, so the check
#     resolves to pass/fail in the plan JSON for the CI gate to read; with
#     `timestamp()` the check stays "unknown" until apply and the gate is blind.

data "aws_eks_cluster_versions" "support_status" {
  include_all = true # include versions already past standard support
}

locals {
  _eks_pinned_match = [
    for v in data.aws_eks_cluster_versions.support_status.cluster_versions :
    v if v.cluster_version == var.cluster_version
  ]
  _eks_end_of_standard_support = (
    length(local._eks_pinned_match) > 0
    ? local._eks_pinned_match[0].end_of_standard_support_date
    : null
  )
}

check "eks_version_in_standard_support" {
  assert {
    condition = (
      local._eks_end_of_standard_support != null
      ? timecmp(plantimestamp(), local._eks_end_of_standard_support) < 0
      : false
    )
    error_message = format(
      "EKS %s is in or near extended support (bills $0.60/hr vs $0.10/hr base) - end of standard support: %s. Bump var.cluster_version to a current GA version (run: aws eks describe-cluster-versions --status STANDARD_SUPPORT). NOTE: on a long-lived cluster this is a control-plane upgrade - scan deprecated APIs (kubent/pluto) and verify addon compatibility first.",
      var.cluster_version,
      coalesce(local._eks_end_of_standard_support, "unknown/unlisted"),
    )
  }
}
