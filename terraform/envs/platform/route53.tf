locals {
  # Per-env subdomain (WS3-R). A hosted zone lives in ONE account, but
  # `envs/platform` applies in BOTH the staging and prod accounts. If both
  # created the same zone name, the registrar could delegate only one — the
  # other would be a ghost zone. So EACH account owns its own env subdomain
  # `<env>.<dns_zone_name>` (e.g. prod.aws.binhsu.org / staging.aws.binhsu.org),
  # delegated DIRECTLY from the registrar (Cloudflare) — one NS record per env
  # subdomain pointing at that account's zone NS. The apex (binhsu.org) stays on
  # Cloudflare (it's the personal homepage). No AWS-side cross-account
  # delegation, no ghost zone, fully symmetric. Route 53 is global — this is an
  # ACCOUNT-boundary fix, not a region one.
  zone_name = "${var.environment}.${var.dns_zone_name}"
}

resource "aws_route53_zone" "main" {
  name = local.zone_name

  # Delegated from Cloudflare: add an NS record under binhsu.org for this zone
  # name (`<env>.aws.binhsu.org`) pointing at this resource's `name_servers`
  # (the zone_name_servers output) — a one-time operator step per env account.
  # ACM DNS-01 validation + the ALB/Cognito alias records hang off this zone.
}
