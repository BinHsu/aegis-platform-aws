# ACM certificate for the public edge (WS3, ADR-19).
#
# DNS-validated against the Route 53 zone (route53.tf). The ALB (gateway
# Ingress) terminates HTTPS with this cert; its ARN is injected onto the
# Ingress via the workload_registries ingress_cert channel (account id stays
# out of the public deploy repo). SANs cover the apex, first-level hosts
# (aegis-api / app / auth), and the staging second-level — one cert serves the
# account whether it runs staging or prod hosts.
#
# NOTE: a Cognito CUSTOM Hosted-UI domain would need its own cert in us-east-1
# (Cognito fronts custom domains with CloudFront). WS3 uses a Cognito PREFIX
# domain instead (cognito.tf), so this regional cert is sufficient for the ALB.

resource "aws_acm_certificate" "platform" {
  domain_name = var.dns_zone_name
  subject_alternative_names = [
    "*.${var.dns_zone_name}",         # aegis-api / app / auth .binhsu.org (prod)
    "*.staging.${var.dns_zone_name}", # *.staging.binhsu.org
  ]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "aegis-platform-${var.dns_zone_name}"
  }
}

# One Route 53 record per distinct validation option (wildcards dedupe to the
# same apex record, so key by the validation record name).
resource "aws_route53_record" "acm_validation" {
  for_each = {
    for dvo in aws_acm_certificate.platform.domain_validation_options :
    dvo.resource_record_name => {
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id         = aws_route53_zone.main.zone_id
  name            = each.key
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "platform" {
  certificate_arn         = aws_acm_certificate.platform.arn
  validation_record_fqdns = [for r in aws_route53_record.acm_validation : r.fqdn]
}

output "acm_certificate_arn" {
  description = "Validated ACM cert ARN for the gateway ALB. Set as ingress_cert.cert_arn in registries.auto.tfvars.json (the ApplicationSet injects it onto the Ingress)."
  value       = aws_acm_certificate_validation.platform.certificate_arn
}
