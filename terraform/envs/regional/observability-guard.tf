# observability-guard.tf — fail-loud precondition for the cross-env coherence.
#
# regional enable_observability=true reads the Grafana Cloud creds the PLATFORM
# env stored in SSM. If the platform env was applied with enable_observability=
# false, those SSM params do not exist and the gc_* lookups would 404 mid-apply.
# Catch that mismatch at plan time instead. Only evaluated when observability is
# on here (count).
resource "terraform_data" "observability_guard" {
  count = var.enable_observability ? 1 : 0

  lifecycle {
    precondition {
      condition     = try(data.terraform_remote_state.platform.outputs.grafana_cloud_ssm_paths.api_token, "") != ""
      error_message = "regional enable_observability = true, but the platform env exposes no Grafana Cloud SSM creds — the platform was applied with enable_observability = false. Enable observability (with creds) in the platform env first, or set this regional env's enable_observability = false."
    }
  }
}
