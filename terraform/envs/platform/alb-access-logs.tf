# ALB access logs land in a dedicated S3 bucket in this platform env. Each
# regional cluster's ALB writes to a `<cluster>/<region>/` prefix so the
# bucket can serve N regions without name collisions. Forensics-only — not
# scraped or dashboarded; pulled into Athena only on incident need.

locals {
  alb_access_logs_bucket_name = "aegis-stateless-alb-access-logs-${data.aws_caller_identity.current.account_id}"
}

# This IS the access-log bucket — meta-logging it would recurse
# (CloudTrail S3 data events are the production audit answer). ALB access
# logs are write-once with a 7-day lifecycle, so versioning adds cost for
# no recovery benefit.
#tfsec:ignore:aws-s3-enable-bucket-logging
#tfsec:ignore:aws-s3-enable-versioning
resource "aws_s3_bucket" "alb_access_logs" {
  bucket = local.alb_access_logs_bucket_name
}

# ALB log delivery only supports SSE-S3 (AES256) — the ALB log-delivery
# service cannot write to a bucket encrypted with a customer-managed KMS
# key. AES256 is a hard AWS constraint here, not a shortcut.
#tfsec:ignore:aws-s3-encryption-customer-key
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id

  rule {
    id     = "expire-7d"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }
  }
}

# Bucket policy granting ELB write access. AWS publishes a list of ELB
# service account IDs per region; we use the elasticloadbalancing.amazonaws.com
# service principal, which works in all currently-supported regions.
data "aws_iam_policy_document" "alb_access_logs" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_access_logs.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "alb_access_logs" {
  bucket = aws_s3_bucket.alb_access_logs.id
  policy = data.aws_iam_policy_document.alb_access_logs.json
}
