terraform {
  required_version = "~> 1.11"

  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.60" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }

  # Bootstrap stays on LOCAL state forever. Its only purpose is to create
  # the S3 bucket that downstream envs use as their remote backend.
  # Migrating bootstrap's own state into that same bucket would create a
  # chicken-and-egg cycle.
  #
  # Per-account isolation is via Terraform WORKSPACES (issue #90): the Makefile
  # runs `terraform workspace select -or-create <ENV>` so each account's local
  # state lives under terraform.tfstate.d/<ENV>/ — no manual -state=<file>
  # juggling when cold-starting a second account.
  #
  # No DynamoDB lock table needed — TF 1.11+ supports native S3 locking
  # via PutObject conditional writes (use_lockfile=true in each downstream
  # backend block). DynamoDB-based locking is deprecated upstream.
}
