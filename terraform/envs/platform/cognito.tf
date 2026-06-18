# Cognito user pool — the public-edge identity provider (WS3, ADR-19).
#
# The gateway validates a Cognito-issued JWT against this pool's JWKS
# (DEPLOY_MODE=cloud → OIDCProvider); the frontend runs the PKCE flow against
# it. Both read provider-neutral inputs ({issuer, audience, jwks}) — Cognito is
# bound as data here, never in the neutral base. One pool per platform apply
# (this env applies once per cluster account, so staging and prod get separate
# pools naturally).
#
# Hosted UI uses a PREFIX domain (…​.auth.<region>.amazoncognito.com), not a
# custom domain, to avoid the us-east-1 cert a custom Cognito domain requires.
# Custom `auth.binhsu.org` is future hardening.

locals {
  # SPA app host for this env's callback/logout allow-list. Matches the
  # per-env zone (route53.tf): app.<env>.<dns_zone_name>, e.g.
  # app.staging.aws.binhsu.org / app.prod.aws.binhsu.org.
  cognito_app_host = "app.${var.environment}.${var.dns_zone_name}"
}

resource "aws_cognito_user_pool" "main" {
  # Env-distinct name (WS3-R): staging and prod each apply this in their own
  # account, so the console shows `aegis-core-staging` / `aegis-core-prod`
  # rather than two identically-named pools.
  name = "aegis-core-${var.environment}"

  # Closed sign-up: Cognito DEFAULTS to allowing self-service SignUp unless this
  # is set, so it must be explicit (CodeRabbit #86). Users are seeded via the
  # console / AdminCreateUser; a public pool with self-service sign-up would let
  # anyone register against the gateway.
  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # Email is the username.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 12
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  # MFA optional (operator can enforce later). TOTP enabled as the second factor.
  mfa_configuration = "OPTIONAL"
  software_token_mfa_configuration {
    enabled = true
  }

  # Tenant claim the gateway maps to a Principal (gateway_go OIDCProvider
  # TenantIDClaim default "custom:tenant_id"; frontend AegisAuthShell reads the
  # same). Mutable so an admin can assign it post-sign-up.
  schema {
    name                     = "tenant_id"
    attribute_data_type      = "String"
    mutable                  = true
    developer_only_attribute = false
    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  # Pre-Token-Generation Lambda (cognito-lambda.tf). REQUIRED for the PKCE/
  # Hosted-UI flow to surface custom:tenant_id in the ID token — read_attributes
  # below grants read access but does NOT put the claim in an OAuth-flow ID token
  # (WS3 2026-06-18). The lambda copies the attribute into the claims.
  lambda_config {
    pre_token_generation = aws_lambda_function.pretoken.arn
  }

  tags = {
    Name = "aegis-core-${var.environment}"
  }
}

# Public SPA client — PKCE, NO client secret (the SPA is a public client).
resource "aws_cognito_user_pool_client" "spa" {
  name         = "aegis-core-spa-${var.environment}"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false # public client (PKCE)

  # Attribute permissions (CodeRabbit #86). By default a client can READ no
  # custom attrs (so custom:tenant_id would be absent from the token) and WRITE
  # all attrs (so a user could set their OWN tenant_id — authz spoofing). Pin
  # both: tenant_id is readable (gateway/frontend map it to the Principal) but
  # NOT writable by end users; only an admin assigns it.
  #
  # NOTE: read access is NECESSARY but NOT SUFFICIENT for the OAuth2/Hosted-UI
  # (PKCE) flow — Cognito does not place a custom attribute into the ID token
  # for that flow on read access alone. The Pre-Token-Generation Lambda
  # (cognito-lambda.tf, wired via the pool's lambda_config) is what actually
  # injects custom:tenant_id into the ID token. Keep read_attributes as-is; it
  # remains required.
  read_attributes  = ["email", "email_verified", "name", "custom:tenant_id"]
  write_attributes = ["email", "name"]

  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  supported_identity_providers         = ["COGNITO"]

  # Callback/logout URLs are ENV-SCOPED (CodeRabbit #87): the pool is per-env, so
  # the staging pool trusts only the staging app host (+ localhost dev), and prod
  # only prod. local.cognito_app_host derives the host from var.environment.
  callback_urls = [
    "https://${local.cognito_app_host}/auth/callback",
    "http://localhost:5173/auth/callback",
  ]
  logout_urls = [
    "https://${local.cognito_app_host}/",
    "http://localhost:5173/",
  ]

  # Access + ID tokens live 1h; refresh 30d. Silent-renew (frontend
  # automaticSilentRenew) keeps long meetings authenticated.
  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  # No implicit flow; auth-code + PKCE only. Prevent user-existence errors from
  # leaking which emails are registered.
  prevent_user_existence_errors = "ENABLED"
}

# Hosted UI prefix domain. Globally unique → suffix with the account id.
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "aegis-core-${data.aws_caller_identity.current.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

output "cognito_issuer" {
  description = "OIDC issuer URL. Feeds the gateway (AEGIS_COGNITO_ISSUER via the aws-binding ConfigMap) and the frontend (/config.json cognito.authority)."
  value       = "https://cognito-idp.${var.platform_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
}

output "cognito_jwks_url" {
  description = "JWKS URL for the gateway OIDCProvider (AEGIS_COGNITO_JWKS_URL)."
  value       = "https://cognito-idp.${var.platform_region}.amazonaws.com/${aws_cognito_user_pool.main.id}/.well-known/jwks.json"
}

output "cognito_app_client_id" {
  description = "SPA app-client id. The gateway audience (AEGIS_COGNITO_AUDIENCE) and the frontend cognito.clientId."
  value       = aws_cognito_user_pool_client.spa.id
}

output "cognito_hosted_ui_domain" {
  description = "Cognito Hosted UI prefix domain (login redirect target)."
  value       = "${aws_cognito_user_pool_domain.main.domain}.auth.${var.platform_region}.amazoncognito.com"
}
