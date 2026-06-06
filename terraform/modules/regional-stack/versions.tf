terraform {
  required_version = "~> 1.11"

  required_providers {
    aws        = { source = "hashicorp/aws", version = "~> 6.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.30" }
    helm       = { source = "hashicorp/helm", version = "~> 2.13" }
    null       = { source = "hashicorp/null", version = "~> 3.0" }
  }
}
