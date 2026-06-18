# Engine model store — the AWS source for the engine's /models CAS (WS3,
# executes ADR-18's deferred AWS side). The engine has no S3 client; the
# aegis-core-deploy aws-binding model-fetch init-container does `aws s3 sync
# s3://<bucket> /models` under IRSA.
#
# PER-REGION (ADR-05 dual-region). This module is instantiated once per enabled
# region (envs/regional, one apply per region, provider region = var.region), so
# the bucket and its read policy land in THIS region. Each region's engine reads
# from its own in-region bucket — no cross-region S3 GET on the model hot path.
# (The previous single bucket in envs/platform only ever lived in platform_region;
# eu-west-1 engines read it cross-region.)
#
# OPERATOR / CI NOTE — model populate is now PER-REGION. The model-populate step
# (operator or CI) must upload the model artifacts to EACH enabled region's
# bucket: aegis-core-models-<acct>-eu-central-1 AND aegis-core-models-<acct>-eu-west-1.
# A region whose bucket is empty fails LOUD at the engine's model-fetch init
# (the `aws s3 sync` gate), it does not silently fall back to another region.

# Globally-unique name: workload + account + region (no random suffix so the
# name is reproducible and the module can wire it into the deploy ConfigMap).
locals {
  model_bucket_name = "aegis-core-models-${data.aws_caller_identity.current.account_id}-${var.region}"
}

resource "aws_s3_bucket" "models" {
  bucket = local.model_bucket_name

  # Teardown-to-zero: the store is a cache of the upstream model artifacts, so a
  # destroy may remove a populated bucket (same posture as ECR force_delete).
  force_destroy = true

  tags = merge(local.common_tags, {
    Name = local.model_bucket_name
  })
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
# this region's bucket; the two verbs `aws s3 sync` performs (ListBucket on the
# bucket, GetObject on its keys). No write — the engine only reads models.
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
  # Region-suffixed: IAM is a global namespace, so two regions in one account
  # would collide on a bare `aegis-core-model-read`. The suffix keeps each
  # region's read policy distinct and self-documenting.
  name        = "aegis-core-model-read-${var.region}"
  description = "Read-only access to the aegis-core engine model bucket in ${var.region} (ADR-18 AWS delivery, ADR-05 per-region)."
  policy      = data.aws_iam_policy_document.model_read.json

  tags = local.common_tags
}
