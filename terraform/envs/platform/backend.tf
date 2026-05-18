terraform {
  backend "s3" {
    # Partial config — bucket, region, encrypt are passed via -backend-config
    # flags (see Makefile target `backend.hcl`, derived from bootstrap's
    # outputs). Hardcoding them here would force a re-edit on every fork.
    key          = "platform/terraform.tfstate"
    use_lockfile = true # TF ≥ 1.11 native S3 locking; no DynamoDB needed.
  }
}
