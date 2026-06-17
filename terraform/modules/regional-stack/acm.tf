# Per-region ACM certificate for the gateway ALB (WS3-R).
#
# ACM certs are REGION-bound: an ALB can only use a cert in its own region. This
# module is instantiated once per region (envs/regional, one apply per enabled
# region), and its `aws` provider is `region = var.region`, so the cert created
# here lands in the correct region automatically — no provider alias needed.
# (The previous single cert in envs/platform only ever covered platform_region.)
#
# Route 53 is global, so the DNS-01 validation records are written to the
# platform-owned zone (var.zone_id) regardless of which region's apply runs.
# Two regions produce the SAME validation CNAME for the same domain, so
# allow_overwrite makes the second write an idempotent no-op.
#
# var.zone_name is the per-env zone (route53.tf): prod = binhsu.org, non-prod =
# <env>.binhsu.org. One wildcard covers every host this env serves
# (aegis-api.<zone>, app.<zone>, …).

locals {
  cert_domain = trimsuffix(var.zone_name, ".")
}

resource "aws_acm_certificate" "gateway" {
  domain_name               = local.cert_domain
  subject_alternative_names = ["*.${local.cert_domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "aegis-gateway-${var.region}"
  }
}

resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.gateway.domain_validation_options :
    dvo.resource_record_name => {
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = var.zone_id
  name            = each.key
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "gateway" {
  certificate_arn         = aws_acm_certificate.gateway.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}
