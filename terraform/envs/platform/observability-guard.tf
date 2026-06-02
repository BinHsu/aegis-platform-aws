# observability-guard.tf — fail-loud precondition for the observability toggle.
#
# enable_observability defaults FALSE so a fork without a Grafana Cloud account
# deploys cleanly out of the box. When an operator opts IN (= true), the grafana
# provider + the gc_* SSM parameters need real creds; without them the apply
# would otherwise fail mid-stream with an opaque grafana-provider 401. This turns
# that into a clear plan-time error. The guard only exists when observability is
# on (count), so the common forker path provisions nothing extra.
resource "terraform_data" "observability_guard" {
  count = var.enable_observability ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.grafana_auth_token != "" && var.grafana_cloud_api_token != ""
      error_message = "enable_observability = true requires grafana_auth_token (glsa_…) and grafana_cloud_api_token (plus the *_url / *_username creds consumed by regional Alloy). Provide them, or set enable_observability = false."
    }
  }
}
