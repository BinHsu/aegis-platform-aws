resource "aws_route53_zone" "main" {
  name = var.dns_zone_name

  # WS3 (ADR-19): real domain `binhsu.org`. The registrar must delegate this
  # zone to the four NS records this resource publishes (a one-time operator
  # step) before public DNS + ACM DNS-01 validation resolve. ACM validation
  # records + the ALB/Cognito/CloudFront alias records hang off this zone.
}
