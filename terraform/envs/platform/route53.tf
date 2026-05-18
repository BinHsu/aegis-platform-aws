resource "aws_route53_zone" "main" {
  name = var.dns_zone_name

  # Placeholder domain — no real registration. DNS is demonstrated via
  # `dig @<our-ns>` against AWS-assigned name servers. Production rollout =
  # register domain + delegate NS records.
}
