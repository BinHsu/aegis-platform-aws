# Engine model store — the AWS source for the engine's /models CAS (WS3,
# executes ADR-18's deferred AWS side). The engine has no S3 client; the
# aegis-core-deploy aws-binding model-fetch init-container does `aws s3 sync
# s3://<bucket> /models` under IRSA. This file provisions the bucket and the
# read-only managed policy the engine's IRSA role attaches (via the
# WorkloadIdentity Claim's policyArns, platform-injected).

# Globally-unique name: workload + account + region (no random suffix so the
# name is reproducible and can be wired into the deploy ConfigMap).
locals {
  model_bucket_name = "aegis-core-models-${data.aws_caller_identity.current.account_id}-${var.platform_region}"
}

resource "aws_s3_bucket" "models" {
  bucket = local.model_bucket_name

  # Teardown-to-zero: the store is a cache of the upstream model artifacts, so a
  # destroy may remove a populated bucket (same posture as ECR force_delete).
  force_destroy = true

  tags = {
    Name = local.model_bucket_name
  }
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket                  = aws_s3_bucket.models.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "models" {
  bucket = aws_s3_bucket.models.id
  versioning_configuration {
    status = "Enabled"
  }
}

#tfsec:ignore:aws-s3-encryption-customer-key
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "models" {
  bucket = aws_s3_bucket.models.id
  rule {
    apply_server_side_encryption_by_default {
      # AES256 (AWS-managed) — same take-home encryption choice as ECR; CMK is
      # documented production hardening (docs/tradeoffs.md).
      sse_algorithm = "AES256"
    }
  }
}

# Read-only managed policy the engine's IRSA role attaches. Scoped to exactly
# this bucket; the two verbs `aws s3 sync` performs (ListBucket on the bucket,
# GetObject on its keys). No write — the engine only reads models.
data "aws_iam_policy_document" "model_read" {
  statement {
    sid       = "ListModelBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.models.arn]
  }
  statement {
    sid       = "ReadModelObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.models.arn}/*"]
  }
}

resource "aws_iam_policy" "model_read" {
  name        = "aegis-core-model-read"
  description = "Read-only access to the aegis-core engine model bucket (ADR-18 AWS delivery)."
  policy      = data.aws_iam_policy_document.model_read.json
}

output "model_bucket_name" {
  description = "Engine model S3 bucket. Set as the aegis-core-deploy aws-binding `aegis-core-model-store` ConfigMap `bucket` value at deploy."
  value       = aws_s3_bucket.models.bucket
}

output "model_read_policy_arn" {
  description = "Managed read policy ARN for the engine IRSA role. Set as engine_irsa.policy_arns in registries.auto.tfvars.json (the ApplicationSet injects it onto the WorkloadIdentity Claim)."
  value       = aws_iam_policy.model_read.arn
}
