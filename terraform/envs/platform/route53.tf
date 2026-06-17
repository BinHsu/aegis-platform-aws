locals {
  # Subdomain-per-env (WS3-R). A hosted zone lives in ONE account, but
  # `envs/platform` applies in BOTH the staging and prod accounts. If both
  # created a zone named `binhsu.org`, the registrar could delegate only one —
  # the other would be a ghost zone (its ACM validation / external-dns / ALB
  # aliases never resolve). So the apex (prod) account owns `binhsu.org`; every
  # non-prod account owns `<env>.<apex>` (e.g. `staging.binhsu.org`), delegated
  # from the apex. Each account is then authoritative for its own names. This
  # matches the existing host split (aegis-api.staging.binhsu.org vs
  # aegis-api.binhsu.org). Route 53 itself is global — this is an ACCOUNT
  # boundary fix, not a region one.
  zone_name = var.environment == "prod" ? var.dns_zone_name : "${var.environment}.${var.dns_zone_name}"
}

resource "aws_route53_zone" "main" {
  name = local.zone_name

  # The registrar (apex) must delegate this zone's NS records before public DNS
  # + ACM DNS-01 validation resolve. For the apex (prod) that is a one-time
  # registrar step; for a child env it is the `subdomain_delegation` record
  # below, created in the apex account. ACM validation + the ALB/Cognito alias
  # records hang off this zone.
}

# Apex-only (prod): delegate each child-env subdomain to the child account's own
# zone via an NS record set. The child zone's NS values come from that account's
# `zone_name_servers` output after its first apply — supplied here via
# var.delegated_subdomains (cross-account; the apex account cannot read the child
# state). No-op (empty map) on non-prod accounts.
resource "aws_route53_record" "subdomain_delegation" {
  for_each = var.environment == "prod" ? var.delegated_subdomains : {}

  zone_id = aws_route53_zone.main.zone_id
  name    = each.key
  type    = "NS"
  ttl     = 172800
  records = each.value
}
