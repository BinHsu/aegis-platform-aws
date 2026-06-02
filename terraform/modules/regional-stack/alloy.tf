# Grafana Alloy — in-cluster collector that:
#   - scrapes node-exporter / kube-state-metrics / cAdvisor (metrics)
#   - receives OTLP gRPC from app SDK (metrics + traces)
#   - receives Pyroscope ingest from app SDK (profiles)
#   - tails pod logs via loki.source.kubernetes (logs)
#   - remote_writes to Grafana Cloud (Mimir / Loki / Tempo / Pyroscope)
#
# Per locked observability decision: this replaces Fluent Bit + the CW
# observability addon. No CloudWatch dashboards / alarms in scope.

resource "kubernetes_namespace" "monitoring" {
  count = var.enable_observability ? 1 : 0

  metadata {
    name = "monitoring"
    labels = {
      # Alloy + subcharts use hostPath / hostNetwork (node-exporter) and
      # need to read kubelet metrics, so the namespace runs `privileged`
      # PSS — not the restricted profile applied to the workload ns.
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

# K8s Secret holding GC credentials. TF reads SSM at regional/ env scope
# (data.aws_ssm_parameter) and passes values in as sensitive module vars.
# Alloy mounts these as env vars and references in its config via env().
resource "kubernetes_secret" "grafana_cloud" {
  count = var.enable_observability ? 1 : 0

  metadata {
    name      = "grafana-cloud-credentials"
    namespace = kubernetes_namespace.monitoring[0].metadata[0].name
  }

  # Keys are UPPERCASE — `envFrom.secretRef` maps each key verbatim to an
  # env var, and the Alloy River config reads them as sys.env("API_TOKEN")
  # etc. Lowercase keys here would silently not match.
  data = {
    API_TOKEN          = var.gc_api_token
    MIMIR_URL          = var.gc_mimir_url
    MIMIR_USERNAME     = var.gc_mimir_username
    LOKI_URL           = var.gc_loki_url
    LOKI_USERNAME      = var.gc_loki_username
    TEMPO_URL          = var.gc_tempo_url
    TEMPO_USERNAME     = var.gc_tempo_username
    PYROSCOPE_URL      = var.gc_pyroscope_url
    PYROSCOPE_USERNAME = var.gc_pyroscope_username
  }

  type = "Opaque"
}

# ---- node-exporter (pinned subchart) --------------------------------------
resource "helm_release" "node_exporter" {
  count      = var.enable_observability ? 1 : 0
  name       = "prometheus-node-exporter"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "prometheus-node-exporter"
  version    = "4.41.0" # pinned

  values = [yamlencode({
    service = {
      port = 9100
    }
  })]
}

# ---- kube-state-metrics (pinned subchart) ---------------------------------
resource "helm_release" "kube_state_metrics" {
  count      = var.enable_observability ? 1 : 0
  name       = "kube-state-metrics"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-state-metrics"
  version    = "5.25.1" # pinned
}

# ---- Alloy ----------------------------------------------------------------
resource "helm_release" "alloy" {
  count      = var.enable_observability ? 1 : 0
  name       = "alloy"
  namespace  = kubernetes_namespace.monitoring[0].metadata[0].name
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = "0.10.1" # pinned

  values = [
    yamlencode({
      controller = {
        # DaemonSet on the host network — one Alloy per node, so app pods
        # reach the OTLP (4317) + Pyroscope (4040) receivers directly at
        # $(NODE_IP):<port> without crossing a Service. hostNetwork is what
        # actually binds those ports on the node IP; extraPorts alone only
        # exposes them inside the pod netns. dnsPolicy ClusterFirstWithHostNet
        # keeps in-cluster DNS working for the apiserver / cAdvisor scrapes.
        type        = "daemonset"
        hostNetwork = true
        dnsPolicy   = "ClusterFirstWithHostNet"
      }
      alloy = {
        # `pyroscope.receive_http` is a public-preview component; Alloy
        # refuses anything below GA by default. Lower the minimum so the
        # Pyroscope receive/write path loads. (--stability.level allows
        # the named level and above.)
        stabilityLevel = "public-preview"
        # Mount the GC credentials secret as env vars.
        envFrom = [{
          secretRef = {
            name = kubernetes_secret.grafana_cloud[0].metadata[0].name
          }
        }]
        # Expose host ports for OTLP gRPC (4317) and Pyroscope (4040)
        # so app pods can reach via $(NODE_IP):4317 / :4040.
        extraPorts = [
          {
            name       = "otlp-grpc"
            port       = 4317
            targetPort = 4317
            protocol   = "TCP"
          },
          {
            name       = "pyroscope"
            port       = 4040
            targetPort = 4040
            protocol   = "TCP"
          },
        ]
        configMap = {
          create = true
          content = templatefile("${path.module}/alloy-config.river.tpl", {
            cluster_name = local.cluster_name
            region       = var.region
          })
        }
      }
    })
  ]

  depends_on = [
    kubernetes_secret.grafana_cloud,
    helm_release.node_exporter,
    helm_release.kube_state_metrics,
  ]
  # depends_on references whole resources (not indexed instances), which is
  # legal even when those resources are count=0 — Terraform treats an empty
  # instance set as "nothing to wait on".
}
