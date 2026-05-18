terraform {
  backend "s3" {
    # Partial config — bucket, key, region, encrypt all passed via
    # -backend-config flags by the Makefile. The key includes the region
    # (e.g. `regional/eu-central-1/terraform.tfstate`) so each region's
    # apply has its own state file and its own lock file — per-region
    # blast-radius isolation.
    use_lockfile = true # TF ≥ 1.11 native S3 locking; no DynamoDB needed.
  }
}
