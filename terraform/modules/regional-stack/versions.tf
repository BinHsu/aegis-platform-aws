terraform {
  required_version = "~> 1.11"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 5.60" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    tls        = { source = "hashicorp/tls", version = "~> 4.0" }
    github     = { source = "integrations/github", version = "~> 6.2" }
  }
}
