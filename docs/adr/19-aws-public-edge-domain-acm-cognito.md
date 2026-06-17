# ADR-19: AWS public edge — real domain, ACM, and Cognito for the WS3 bring-up

## Status

Accepted. Application + manifest work done 2026-06-17 (frontend `/config.json`
runtime-config refactor in `aegis-core`; `aws-binding` Cognito/OIDC env
injection + Ingress host parameterization in `aegis-core-deploy`). Terraform for
the AWS resources below is **authored but not applied** — the apply rides the
WS3 bring-up (issue #47), which is gated on `make bootstrap` and is billable.

## Context

WS3 (#47) deploys `aegis-core` (engine + gateway + frontend) onto the governed
AWS platform for real. The platform's edge — how a user reaches the product over
the public internet, with TLS and authentication — has three gaps that the
take-home-era placeholders left open:

1. **Domain.** The Route 53 zone is `aegis-platform.test` (`terraform/envs/platform/variables.tf`).
   `.test` is RFC 6761-reserved and never delegated publicly, so it **cannot get
   a public ACM certificate** — DNS-01 validation needs a publicly resolvable
   name. Good enough to demonstrate DNS with `dig`; not good enough for real
   HTTPS.
2. **TLS.** No ACM certificate exists in Terraform. The gateway Ingress
   (`aegis-core-deploy` `components/aws-binding/gateway-ingress.yaml`) references
   a platform-injected `certificate-arn` that nothing currently provisions.
3. **Auth.** No Cognito resources exist in this repo's Terraform.

### Load-bearing finding: the auth is already built, and already neutral

Reading the source before designing settled the shape:

- **Frontend** (`aegis-core/frontend_web`) already integrates Cognito via
  `react-oidc-context` / `oidc-client-ts` (`src/lib/auth.ts`). It was only ever
  *build-time* configured (baked `VITE_AEGIS_COGNITO_*`).
- **Gateway** (`aegis-core/gateway_go`) already ships a production, RS256,
  JWKS-validating `OIDCProvider` (`internal/auth/oidc_provider.go`) selected by
  `DEPLOY_MODE=cloud`, configured by exactly `{issuer, audience, jwksUrl}`
  (`cmd/gateway/main.go` `buildAuthProvider`).

So this ADR is about **provisioning the AWS-side resources and wiring their
values in**, not designing an auth flow.

## Decision

### 1. Real domain: per-env subdomain under `aws.binhsu.org`

Replace the `.test` placeholder with real DNS, but keep the `binhsu.org` apex on
Cloudflare (it's the personal homepage). `dns_zone_name = aws.binhsu.org`; each
account owns its own Route 53 zone `<env>.aws.binhsu.org` (prod →
`prod.aws.binhsu.org`, staging → `staging.aws.binhsu.org`), **delegated directly
from Cloudflare** with one NS record per env subdomain pointing at that
account's zone name servers. Symmetric, fully account-isolated, no AWS-side
cross-account delegation, no ghost zone. Registrar delegation (the per-env NS
records in Cloudflare) is a one-time **operator step**, not Terraform.

Hostnames: `aegis-api.staging.aws.binhsu.org` (staging gateway) /
`aegis-api.prod.aws.binhsu.org` (prod gateway); `app.<env>.aws.binhsu.org` (SPA);
the Cognito Hosted UI on its prefix domain (`…​.auth.<region>.amazoncognito.com`;
a custom domain is future hardening — it needs a us-east-1 cert).

### 2. TLS via ACM

A **per-region** `aws_acm_certificate` (regional module, DNS-validated against
the env's Route 53 zone) covers `<env>.aws.binhsu.org` + `*.<env>.aws.binhsu.org`
(the Cognito Hosted UI runs on its own prefix domain with Cognito's managed
cert). The ALB terminates HTTPS; the cert ARN is injected
onto the Ingress by the platform ApplicationSet (it embeds the account id, so it
stays out of the public deploy repo — same posture as the ECR account id).

### 3. Cognito

Per-environment (staging / prod): an `aws_cognito_user_pool`, a **public**
`aws_cognito_user_pool_client` (PKCE, no client secret; callback/logout URLs on
`binhsu.org`), and an `aws_cognito_user_pool_domain` (Cognito **prefix** domain
for the Hosted UI — a custom `auth.binhsu.org` is deferred; it requires a
us-east-1 cert). A staging user pool already exists (landing-zone-owned, surfaced in
`aegis-core`'s frontend workflow). Outputs — issuer
(`https://cognito-idp.<region>.amazonaws.com/<pool-id>`), app-client-id, jwks
URL — feed both consumers.

### 4. Auth terminates at the gateway (OIDC JWT validation), NOT at the ALB

The SPA runs the Cognito PKCE flow in-browser, gets a JWT, and sends it as
`Authorization: Bearer` on gRPC-Web calls; the gateway validates it against the
Cognito JWKS. We do **not** use the ALB's native `authenticate-cognito` action,
for two reasons:

- **gRPC.** `authenticate-cognito` is an HTTP redirect flow; it cannot cover the
  gateway's gRPC / gRPC-Web traffic.
- **Neutrality (ADR-16).** Gateway auth is `{issuer, jwks_uri, audience}` — the
  same OIDC discovery shape for Cognito (AWS) and Dex/Keycloak (on-prem). The
  binding injects the provider's values; the base carries none. ALB-native auth
  would weld the edge to AWS and break the additive-binding contract.

The values are injected by `aws-binding` (gateway: the `aegis-core-gateway-oidc`
ConfigMap → `AEGIS_COGNITO_ISSUER/AUDIENCE/JWKS_URL`; frontend: the ADR-15
`/config.json`). On-prem injects Dex equivalents (carry-forward, off the WS3
path).

### 5. Frontend runtime config is the injection point (ADR-15)

The `/config.json` refactor (done in WS3) is what lets ONE immutable bundle carry
per-environment API endpoint **and** Cognito client config — the prerequisite
that makes Cognito a swap-in value rather than a rebuild.

## Consequences

- Real HTTPS on `binhsu.org`; the `.test` `dig`-only posture is retired. New
  bootstrap prerequisite: delegate the zone at the registrar.
- Public PKCE client → no client secret to store. localStorage token persistence
  is carried over from the existing frontend (its XSS tradeoff is documented in
  `aegis-core` `src/lib/auth.ts`; revisit when the pool goes live).
- Per-environment pools keep staging and prod identities isolated.
- Because the gateway and frontend auth were already built and neutral, WS3 adds
  **no application redesign** — only AWS resources + value injection.

## Related WS3 binding decisions (recorded here, executions of prior ADRs)

- **Model delivery = IRSA `aws s3 sync` init-container** (executes ADR-18's
  deferred AWS side). IRSA collapses the on-prem SPIRE→STS→mc three-step chain to
  one init-container: the EKS pod-identity webhook + AWS SDK do the
  web-identity exchange transparently. Chosen over a Mountpoint-S3 CSI mount
  (which ADR-18 floated) for fewer cluster prerequisites and a faithful mirror of
  the proven on-prem delivery pattern. The engine's IRSA role gets an S3-read
  managed policy (Terraform) attached via the WorkloadIdentity Claim's
  `policyArns`, platform-injected.
- **`DEPLOY_MODE` neutrality fix.** The base gateway Rollout carried
  `AEGIS_DEPLOY_MODE: CLOUD` — both non-neutral and a misname (the Go gateway
  reads `DEPLOY_MODE`, so it was dead config; tracing + auth would have mis-fired
  on first real deploy). Removed from base; each binding now injects
  `DEPLOY_MODE` (aws=`cloud`, onprem=`local`), per ADR-16.
- **CI digest commit-back** (executes ADR-14/17). `aegis-core`'s
  `release-staging-image.yml` now pins the staging overlay **by digest** (gateway
  + engine + seed, atomically) into per-workload JSON6902 patch files, instead of
  writing mutable tags into the neutral base.
