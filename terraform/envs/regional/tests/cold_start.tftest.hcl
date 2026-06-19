# Cold-start gate for the regional stack — Terraform `test` (TF 1.6+), mock-only.
#
# WHY THIS EXISTS (ADR-21 §D.2 layer 1): prod was the first env to ever cold-start
# from true zero, and that surfaced five latent bugs ON the prod path — the most
# expensive place to find them (#106 empty-state plan, #107 zone-fallback
# placeholders, #108 region-suffix IAM-name collisions, #103 orphaned state lock,
# the §A IAM orphan). This test moves the plan-time classes of those bugs OFF the
# prod path: it plans the regional stack from an EMPTY platform remote-state and
# asserts the plan still succeeds with well-formed shapes — at PR time, free, with
# ZERO AWS calls (mock_provider) and ZERO cost (`command = plan` creates nothing).
#
# WHAT IT LOCKS IN (the three bug classes the task names):
#   1. Empty remote-state survival — override the platform remote_state to return
#      BLANK outputs and assert the regional plan still SUCCEEDS. This is the
#      try()+valid-placeholder contract from envs/regional/main.tf (the v0.2.1/
#      v0.2.2 fixes); the test fails the moment someone removes a try() or a
#      placeholder and a bare output reference hard-fails the cold-start plan.
#   2. Provider-rejected computed shapes — assert the planned ACM cert SAN does
#      NOT end in "." (empty zone_name -> "*.") and the planned Route53 validation
#      record's zone_id is NON-EMPTY. With mock_provider there is no provider-side
#      validation, so we assert on the PLANNED VALUES the real provider rejected.
#   3. IAM global-name collision guard — #117 added aws_iam_role.engine named
#      "aegis-core-engine-${region}". Assert the planned role name CONTAINS the
#      region (the EntityAlreadyExists dual-region class, ADR-21 §C).
#
# ── HOW THE PLAN IS SCOPED, AND WHY (honest coverage note) ──────────────────────
# The regional-stack module plans an EKS cluster (terraform-aws-modules/eks v21),
# ~10 helm_release resources, kubernetes_* resources, and external data sources.
# The kubernetes + helm providers are configured via `exec` against an endpoint
# that is UNKNOWN at plan on a cold start (module.stack.cluster_endpoint), and the
# helm_release resources reference live chart repos. Mocking those providers
# (mock_provider "kubernetes"/"helm") lets the plan walk the whole tree without a
# cluster or network.
#
# COVERAGE: this is a FULL-MODULE plan (command = plan over envs/regional, which
# calls module.stack = the whole regional-stack). Every cold-start-critical
# resource the three bug classes touch — the platform remote_state reads + try()
# fallbacks (main.tf), aws_acm_certificate.gateway + aws_route53_record.acm_validation
# (acm.tf), and aws_iam_role.engine (pod-identity-engine.tf, the #117 surface) — is
# IN the planned tree, so the asserts hit real planned values.
#
# COVERAGE GAP (named, not faked — repo discipline): mock_provider returns SYNTHETIC
# values for *computed* (unknown-at-plan) attributes, so a few real-provider checks
# are NOT reproducible here and are called out in the report:
#   - real provider-side rejection of an empty zone_id / a SAN ending in "." (the
#     errors #107 actually threw) only fires against the REAL aws provider at plan.
#     We instead assert the INPUTS that feed those shapes are well-formed (the
#     placeholder zone_id is a non-empty Z-id, the SAN's domain is non-empty), which
#     is the controllable, mock-stable equivalent. A real-provider plan is layer (1)'s
#     job in CI against real state; this gate is the free pre-AWS backstop.
#   - EntityAlreadyExists itself is an APPLY-time AWS error; a plan (mock or real)
#     cannot raise it. We assert the NAME SHAPE that prevents it (region in the name).

# All three AWS providers (default + the aws.platform alias) are mocked so the plan
# makes zero real calls. The EKS submodule's own aws data sources resolve against
# these mocks too.
#
# Two data sources need REAL-shaped mock values (a random mock value breaks the
# plan, not the cold-start contract under test):
#   - aws_iam_policy_document.json must be valid JSON — both pod-identity-engine.tf
#     (aws_iam_role.engine.assume_role_policy, OUR target) and the EKS submodule's
#     node-group roles feed .json into assume_role_policy, which the provider parses
#     at plan. A random string => "not a JSON object". We return a minimal valid
#     policy object so the plan proceeds; the SHAPE of the engine role's name (the
#     real assertion) is unaffected by the trust-policy body.
#   - aws_availability_zones.names must have >= 3 entries — locals.tf does
#     slice(names, 0, 3); a shorter mock list errors "end index > length".
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
    }
  }
  # The EKS submodule builds managed-policy ARNs as arn:${partition}:iam::aws:policy/…;
  # a random mock partition fails ARN validation. Pin the real commercial partition.
  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
  # The EKS submodule reads aws_caller_identity then feeds .arn into
  # aws_iam_session_context, which validates ARN shape. A random mock arn fails
  # "invalid prefix". Pin a well-formed account + arn.
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
      arn        = "arn:aws:iam::111122223333:role/mock-apply"
      user_id    = "AIDAMOCKUSERID"
    }
  }
  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::111122223333:role/mock-apply"
    }
  }
  # eks-version-guard.tf has a `check` block that asserts var.cluster_version is in
  # standard support. A failed check fails the run, so we feed the guard a mock
  # versions list containing the pinned version (default 1.35) with a FUTURE
  # end-of-standard-support date. This keeps the orthogonal cost-guard green during
  # the cold-start plan; it does not weaken any cold-start assertion below.
  mock_data "aws_eks_cluster_versions" {
    defaults = {
      cluster_versions = [
        {
          cluster_version              = "1.35"
          end_of_standard_support_date = "2099-12-31T00:00:00Z"
        }
      ]
    }
  }
}
mock_provider "aws" {
  alias = "platform"
}

# kubernetes + helm are exec-auth'd against a cluster that does not exist on a cold
# start. Mock them so the plan walks the helm_release / kubernetes_* tree without a
# live API server or chart-repo network.
mock_provider "kubernetes" {}
mock_provider "helm" {}

# Fixtures matching the env's required vars (region/node_*/platform_region/
# tfstate_*/github_token/operator_principal_arn). Values mirror a real eu-central-1
# regional apply; tfstate_* are placeholders — the remote_state is overridden below,
# so they are never dialed. NOTE (WS4 / ADR-23): vpc_cidr is no longer a var — the
# CIDR is allocated from the landing-zone IPAM pool (mocked above), so there is
# nothing to set here.
variables {
  region                 = "eu-central-1"
  environment            = "staging"
  node_instance          = "t3.large"
  node_min               = 2
  node_max               = 4
  platform_region        = "eu-central-1"
  tfstate_bucket         = "mock-tfstate-bucket"
  tfstate_region         = "eu-central-1"
  github_token           = "mock-github-token"
  operator_principal_arn = "arn:aws:iam::111122223333:user/mock-operator"
  enable_observability   = false
  workload_registries = {
    "aegis-core-deploy" = {
      ecr_account_id = "162975888022"
      ecr_region     = "eu-central-1"
      engine_irsa = {
        service_account = "aegis-core-engine"
        role_name       = "aegis-core-engine"
        policy_arns     = []
      }
    }
  }
}

# ── RUN: cold-start plan against an EMPTY platform remote state ─────────────────
# This is the heart of the gate. override_data replaces the platform remote_state
# data source with EMPTY outputs (zero keys) — exactly what a never-applied platform
# account returns. command = plan creates nothing. If the plan SUCCEEDS, the
# try()+placeholder contract in main.tf held; if a bare output reference were
# reintroduced, the plan would error here ("object has no attribute").
run "cold_start_empty_platform_state_plans_clean" {
  command = plan

  # Empty platform outputs — the never-applied-account shape. Every reference in
  # main.tf (infra_ci/apply/destroy role ARNs, zone_id, zone_name, cognito_*,
  # grafana_cloud_ssm_paths) is wrapped in try(); with no outputs here each try()
  # must fall back, and the plan must still complete.
  override_data {
    target = data.terraform_remote_state.platform
    values = {
      outputs = {}
    }
  }

  # WS4 / ADR-23: the regional VPC CIDR is allocated from the landing-zone IPAM
  # pool (regional-stack/vpc-ipam.tf), resolved by locale. The module derives the
  # pool id from the data source ARN (NOT .id — .id is the SDK identity, not a
  # schema attribute, so it is unmockable; see vpc-ipam.tf). Override .arn with a
  # well-formed IPAM-pool ARN so the derived ipam_pool_id is KNOWN and non-null at
  # plan. The allocation's .cidr stays unknown-after-apply, so this run still
  # exercises the real cold-start contract: subnets derived from an UNKNOWN cidr
  # over a static range(3) — known count, unknown values, no for_each on the
  # unknown — must plan clean.
  override_data {
    target = module.stack.data.aws_vpc_ipam_pool.regional
    values = {
      arn = "arn:aws:ec2::111122223333:ipam-pool/ipam-pool-00000000000000000"
    }
  }

  # MOCK LIMITATION (named, not faked): aws_route53_record.acm_validation does
  # for_each over aws_acm_certificate.gateway.domain_validation_options. The REAL
  # aws provider computes that set's shape at plan from the (known) domain_name +
  # SAN, so a real cold-start plan expands the for_each fine. mock_provider returns
  # the whole set as unknown-after-apply, which fails for_each ("cannot determine
  # the full set of keys"). We override JUST the cert's domain_validation_options
  # with a known single entry so the for_each can expand under mocks. domain_name
  # and subject_alternative_names are CONFIGURED args (from local.cert_domain =
  # var.zone_name), NOT overridden here, so the CLASS-2 SAN assertion below still
  # reads the real planned SAN.
  override_resource {
    target          = module.stack.aws_acm_certificate.gateway
    override_during = plan
    values = {
      domain_validation_options = [
        {
          domain_name           = "placeholder.example.com"
          resource_record_name  = "_mockvalidation.placeholder.example.com"
          resource_record_type  = "CNAME"
          resource_record_value = "mock.acm-validations.aws."
        }
      ]
    }
  }

  # The destroy_role_in_platform_state CHECK (main.tf) is DESIGNED to fire on an
  # empty/stale platform state — it warns (does not block apply) that the
  # infra_destroy access entry will be omitted. On a true cold start (empty
  # outputs) it MUST fire, so we expect it. This is the documented cold-start
  # warning behavior, not a regression: asserting the check fires here locks in
  # that the warning still surfaces (a silent omission stranded a billing cluster,
  # 2026-06-06). The real apply flow (apply-platform -> apply-regional) sees a
  # populated state, so the check passes there.
  expect_failures = [
    check.destroy_role_in_platform_state,
  ]

  # CLASS 1 — empty-state survival: the plan reached completion. (A run that errors
  # fails the test outright; this assert documents intent + pins one concrete
  # fallback: the engine role name was computable from the empty-state plan.)
  assert {
    condition     = module.stack.engine_iam_role_name != ""
    error_message = "Cold-start plan against EMPTY platform state did not produce an engine IAM role name — a try()/placeholder fallback in main.tf likely regressed."
  }

  # CLASS 3 — IAM global-name collision guard (#117 / ADR-21 §C): the engine role
  # name MUST contain the region. A bare "aegis-core-engine" collides across two
  # regions in one account (EntityAlreadyExists at apply). This is the exact name
  # shape pod-identity-engine.tf introduced.
  assert {
    condition     = strcontains(module.stack.engine_iam_role_name, var.region)
    error_message = "Engine IAM role name does not contain the region — dual-region EntityAlreadyExists hazard (ADR-21 §C). Expected the name to embed ${var.region}."
  }
  assert {
    condition     = module.stack.engine_iam_role_name == "aegis-core-engine-${var.region}"
    error_message = "Engine IAM role name is not the expected region-suffixed 'aegis-core-engine-${var.region}'."
  }

  # The model-read managed policy is the OTHER region-suffixed name in the §C class
  # (the #108 name that orphaned + collided). Guard it the same way.
  assert {
    condition     = strcontains(module.stack.model_read_policy_name, var.region)
    error_message = "model-read policy name does not contain the region — the #108 collision class. Expected 'aegis-core-model-read-${var.region}'."
  }

  # Phase 4c: the model-populator role + write policy are the newest names in the
  # §C region-suffix class (pod-identity-model-populator.tf). A bare name collides
  # across two regions in one account (EntityAlreadyExists at apply), exactly like
  # #108. Guard both the role and the policy name shapes.
  assert {
    condition     = module.stack.model_populator_iam_role_name == "aegis-core-model-populator-${var.region}"
    error_message = "model-populator IAM role name is not the expected region-suffixed 'aegis-core-model-populator-${var.region}' — dual-region EntityAlreadyExists hazard (ADR-21 §C)."
  }
  assert {
    condition     = module.stack.model_write_policy_name == "aegis-core-model-write-${var.region}"
    error_message = "model-write policy name is not the expected region-suffixed 'aegis-core-model-write-${var.region}' — the #108 collision class."
  }

  # CLASS 2 — provider-rejected shape: ACM cert SAN. On a cold start the zone_name
  # falls back to the syntactically-valid placeholder "placeholder.example.com"
  # (main.tf), NOT "". An empty zone_name would build SAN ["*."] which the real
  # provider rejects ("SAN ending in '.'"). Assert the planned SAN does NOT end in
  # ".", i.e. the placeholder did its job.
  assert {
    condition     = !endswith(one(module.stack.gateway_cert_sans), ".")
    error_message = "ACM cert SAN ends in '.' — empty zone_name fed '*.' which the real provider rejects at plan (#107). The zone_name placeholder fallback regressed."
  }
  # The cert domain_name itself must be non-empty (the apex the SAN wildcards over).
  assert {
    condition     = module.stack.gateway_cert_domain_name != ""
    error_message = "ACM cert domain_name is empty on the cold-start plan — zone_name placeholder fallback regressed (#107)."
  }
}

# ── RUN: same plan, asserting the Route53 zone_id shape (CLASS 2, second shape) ──
# The acm_validation record's zone_id comes from var.zone_id, which on a cold start
# falls back to the placeholder "Z0PLACEHOLDERGATEPLAN" (main.tf) — NOT "". The real
# provider rejects an empty zone_id ("zone_id must not be empty"). Because the
# record is for_each'd on DOMAIN-validation options that are computed/unknown under
# mocks, the set may be empty at plan; we therefore assert on the INPUT the record
# consumes (var.zone_id as resolved into the module) — the controllable equivalent.
run "cold_start_zone_id_placeholder_is_nonempty" {
  command = plan

  override_data {
    target = data.terraform_remote_state.platform
    values = {
      outputs = {}
    }
  }

  # WS4 / ADR-23: same IPAM-pool override as the first run — set .arn (the
  # mockable attribute the module derives the pool id from) so the /16 allocation
  # has a non-null ipam_pool_id at plan; .cidr stays unknown.
  override_data {
    target = module.stack.data.aws_vpc_ipam_pool.regional
    values = {
      arn = "arn:aws:ec2::111122223333:ipam-pool/ipam-pool-00000000000000000"
    }
  }

  # Same mock limitation as the first run — give the ACM cert a known
  # domain_validation_options so the route53 for_each expands under mocks.
  override_resource {
    target          = module.stack.aws_acm_certificate.gateway
    override_during = plan
    values = {
      domain_validation_options = [
        {
          domain_name           = "placeholder.example.com"
          resource_record_name  = "_mockvalidation.placeholder.example.com"
          resource_record_type  = "CNAME"
          resource_record_value = "mock.acm-validations.aws."
        }
      ]
    }
  }

  expect_failures = [
    check.destroy_role_in_platform_state,
  ]

  # The zone_id the module received must be non-empty on a cold start (the
  # placeholder, not ""). This is the value aws_route53_record.acm_validation feeds
  # to zone_id; a "" here is exactly the #107 empty-zone_id the provider rejects.
  assert {
    condition     = module.stack.zone_id_in_use != "" && module.stack.zone_id_in_use != null
    error_message = "Module received an empty/null zone_id on the cold-start plan — the Z-id placeholder fallback in main.tf regressed (#107: provider rejects an empty zone_id)."
  }
  # And it must look like a Route53 zone id (starts with 'Z'), so it is a shape the
  # provider would accept, not just any non-empty string.
  assert {
    condition     = startswith(module.stack.zone_id_in_use, "Z")
    error_message = "zone_id placeholder is not a Z-id shape — the real provider expects a Route53 zone id."
  }
}
