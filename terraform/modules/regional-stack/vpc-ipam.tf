# VPC CIDR from the landing-zone IPAM pool (WS4 / ADR-23).
#
# WHY: the regional VPC CIDR was a hardcoded /16 fed by CI from
# regions.auto.tfvars.json (.regions[r].cidr). A hand-managed CIDR per region
# is exactly the kind of value that silently overlaps once you run more than
# one region — there is nothing stopping two regions, or two accounts, from
# picking the same /16. The landing-zone IPAM is the single allocator: it owns
# the address space and hands out non-overlapping blocks. This stack now asks
# IPAM for its /16 instead of carrying its own number.
#
# RESOLVE BY LOCALE, NOT BY ID: the landing zone RAM-shares one regional IPAM
# pool per region; each pool's `locale` equals its region. We resolve the pool
# by `locale = var.region` (+ address-family ipv4) so a hardcoded pool id never
# lands in source and the same module plans correctly in every region — the
# default aws provider runs in var.region, so the locale filter returns the one
# in-region pool. The data source errors if the filter matches 0 or >1 pools,
# which is the correct fail-loud: a missing RAM share or a duplicate pool is a
# landing-zone misconfig we want surfaced at plan, not a silent wrong CIDR.
data "aws_vpc_ipam_pool" "regional" {
  filter {
    name   = "locale"
    values = [var.region]
  }

  filter {
    name   = "address-family"
    values = ["ipv4"]
  }
}

locals {
  # The pool id, derived from the data source ARN rather than its `.id`.
  #
  # WHY NOT .id: the aws_vpc_ipam_pool data source sets its `id` via SetId()
  # (the SDK identity), NOT as a schema attribute — so the Terraform test mock
  # framework cannot populate it (mock_data/override_data only reach schema
  # attributes), and a referencing required argument resolves to null at plan
  # under mock_provider, breaking the cold-start gate. `.arn` IS a schema
  # attribute (mockable), and the IPAM pool ARN is
  # arn:aws:ec2::<acct>:ipam-pool/<pool-id> by construction, so the last path
  # segment IS the pool id — identical to .id at real apply, but mockable in the
  # cold-start test. Verified against the live RAM-shared pool ARN.
  ipam_pool_id = element(split("/", data.aws_vpc_ipam_pool.regional.arn), 1)
}

# Reserve a /16 from the resolved pool. This is a real allocation (not a
# preview) so the block is durably reserved against this VPC — re-running the
# plan does not re-roll the CIDR, and another region/account cannot be handed
# the same range.
#
# PLAN-TIME NOTE (why this plans clean on a cold start): .cidr is
# known-after-apply (IPAM picks the block at CreateVpc time). That is fine:
#   - module.vpc consumes it as a plain `cidr` string — an unknown string input
#     plans clean.
#   - locals.tf derives subnets via cidrsubnet(<unknown cidr>, 4, i) over a
#     STATIC range(3). The VALUES are unknown at plan but the COUNT is known
#     (3 public + 3 private), so the subnet resources expand at plan; only their
#     cidr_block attributes are unknown-after-apply. No for_each/count is keyed
#     on the unknown cidr, so there is no "cannot determine the full set of
#     keys" failure.
# (terraform-aws-modules/vpc README documents the same constraint: subnets must
# be derived from a single CIDR known at plan OR from an allocation whose value
# the module treats as an opaque string — which is exactly this path.)
resource "aws_vpc_ipam_pool_cidr_allocation" "regional" {
  ipam_pool_id   = local.ipam_pool_id
  netmask_length = 16
}
