# Frontend SPA edge — private S3 origin + CloudFront (OAC) + ACM (us-east-1) +
# Route 53 alias. WS3: closes the gap where the staging frontend bucket and
# distribution were an LZ-era singleton with no IaC owner — they were last
# provisioned in April, vanished across the multi-repo split + teardown cycles,
# and surfaced as `NoSuchBucket` the first time release-staging-frontend.yml
# re-ran (2026-06-18). Reproducible here in the platform tier, which is
# account-scoped and survives a region teardown (so the SPA edge no longer
# evaporates when the regional EKS stack is destroyed).
#
# The SPA host MUST equal the Cognito callback host (cognito.tf): the OIDC PKCE
# redirect_uri is checked against Cognito's allow-list, so any drift breaks
# login. Referencing local.cognito_app_host (not a second copy) makes drift
# impossible by construction.

locals {
  # Deterministic name (no random suffix) so the bootstrap IAM grant (Role F)
  # and aegis-core's FRONTEND_BUCKET var can hard-code it. For staging this is
  # exactly `aegis-staging-frontend-<account_id>`.
  frontend_bucket_name = "aegis-${var.environment}-frontend-${data.aws_caller_identity.current.account_id}"
  frontend_app_host    = local.cognito_app_host # app.<env>.<dns_zone_name>
}

resource "aws_s3_bucket" "frontend" {
  bucket = local.frontend_bucket_name

  # The bundle is a pure build artifact (CI re-syncs it on every release), so a
  # teardown may remove a populated bucket — same posture as the model store.
  force_destroy = true

  tags = {
    Name = local.frontend_bucket_name
  }
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#tfsec:ignore:aws-s3-encryption-customer-key
#trivy:ignore:AVD-AWS-0132
resource "aws_s3_bucket_server_side_encryption_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    apply_server_side_encryption_by_default {
      # AES256 (AWS-managed) — same take-home encryption choice as the model
      # store + ECR; CMK is documented production hardening (docs/tradeoffs.md).
      sse_algorithm = "AES256"
    }
  }
}

# Origin Access Control — CloudFront sigv4-signs every origin request so the
# bucket stays fully private (no public-read, no legacy OAI).
resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${local.frontend_bucket_name}-oac"
  description                       = "OAC for the aegis ${var.environment} frontend SPA bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# CloudFront only honours certs in us-east-1, regardless of the bucket region.
resource "aws_acm_certificate" "frontend" {
  provider          = aws.us_east_1
  domain_name       = local.frontend_app_host
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = local.frontend_app_host
  }
}

# DNS-01 validation records in this env's hosted zone. One domain, no SANs, so
# the for_each yields a single record; the map shape keeps it re-apply-safe.
resource "aws_route53_record" "frontend_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.frontend.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = aws_route53_zone.main.zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "frontend" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.frontend.arn
  validation_record_fqdns = [for r in aws_route53_record.frontend_cert_validation : r.fqdn]
}

# AWS-managed CachingOptimized policy — looked up by name so there is no magic
# constant to drift.
data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "aegis ${var.environment} frontend SPA"
  default_root_object = "index.html"
  aliases             = [local.frontend_app_host]
  # NA + EU edge locations — the audience is eu-central-1; the cheapest class
  # that still covers it.
  price_class = "PriceClass_100"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "s3-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-frontend"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id
  }

  # SPA client-side routing: S3 returns 403 (OAC, no public list) / 404 for any
  # non-asset path, so map both to index.html/200 and let the router resolve the
  # route. index.html + config.json carry short TTLs from the S3 sync step
  # (release-staging-frontend.yml); content-hashed assets stay immutable.
  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 10
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.frontend.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name = "aegis-${var.environment}-frontend"
  }
}

# Bucket policy — grant read to ONLY this distribution (OAC SourceArn condition).
data "aws_iam_policy_document" "frontend_bucket" {
  statement {
    sid       = "AllowCloudFrontOACRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.frontend.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_bucket.json
}

# Public alias → CloudFront (CloudFront's own hosted_zone_id, not the env zone).
resource "aws_route53_record" "frontend_alias" {
  zone_id = aws_route53_zone.main.zone_id
  name    = local.frontend_app_host
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.frontend.domain_name
    zone_id                = aws_cloudfront_distribution.frontend.hosted_zone_id
    evaluate_target_health = false
  }
}

output "frontend_bucket" {
  description = "Frontend SPA S3 bucket. Equals aegis-core's FRONTEND_BUCKET var (deterministic name)."
  value       = aws_s3_bucket.frontend.bucket
}

output "frontend_cloudfront_distribution_id" {
  description = "Frontend CloudFront distribution id. Set this as aegis-core's FRONTEND_CLOUDFRONT_DISTRIBUTION_ID GH variable — it replaces the stale LZ-era E5PYHGEEZQ7M8 (the id changes whenever the distribution is recreated)."
  value       = aws_cloudfront_distribution.frontend.id
}

output "frontend_url" {
  description = "Public SPA URL."
  value       = "https://${local.frontend_app_host}"
}
