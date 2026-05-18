terraform {
  required_version = "~> 1.11"

  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.60" }
    grafana = { source = "grafana/grafana", version = "~> 3.10" }
    github  = { source = "integrations/github", version = "~> 6.2" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}
