# ADR-20: How the gateway gets the tenant id from a Cognito token

> **Status: Accepted** (2026-06-19, reviewed by Bin). The decision below — keep the
> Pre-Token-Generation Lambda — is committed.

## 中文摘要

Gateway 用 Cognito ID token 裡的 `custom:tenant_id` claim 來判斷租戶。BVA 測試
抓到一個 bug:Cognito 的 Hosted-UI / OAuth2 (PKCE) flow **不會**把 custom 屬性放進
ID token(只給 read 權限不夠),所以真實 PKCE 登入拿到的 id_token 沒有
`custom:tenant_id`,gateway 一律回 `missing tenant id claim`。目前已上線的修法
(PR #101)是一支 **Pre-Token-Generation Lambda (V1)**,把 `custom:tenant_id`
複製進 ID token claims —— 這正是 AWS 文件指定的「往 token 加 custom claim」機制,
staging 實證可行。本 ADR 評估能不能為 prod 拿掉 Lambda(降低運維面)。結論:
**保留 Lambda(option 1)**。其他三條路都更貴或更不乾淨 —— groups (option 2) 把
tenant 硬塞進 coarse 的 authz 群組、語意失真又有上限;config-only 無 Lambda
(option 3)在 Cognito 並不存在;改驗 access token (option 4) 只是把 Lambda 從
V1 搬到 V2、還要升 Essentials 付費 tier,Lambda 沒少反而多花錢。Lambda 本身是
per-pool 設定,prod 雙區(eu-central-1 + eu-west-1,每帳號一個 pool)各複製一份,
Terraform 的 `for_each` / per-env apply 本就自然做到。

## Status

Accepted (2026-06-19).

## Context

The gateway authorizes every gRPC / gRPC-Web request by mapping a Cognito JWT
claim to a `Principal`: `sub → UserID`, `custom:tenant_id → TenantID`
(`aegis-core/gateway_go/internal/auth/oidc_provider.go`,
`OIDCProvider.Authenticate`; `TenantIDClaim` defaults to `custom:tenant_id` in
`jwt.go`). A missing or empty `custom:tenant_id` is a hard reject — there is no
fallback to an empty tenant, by design (it would conflate with LOCAL-mode
semantics). The frontend SPA signs users in with the OAuth2 authorization-code +
PKCE flow against the Cognito **Hosted UI**, and sends the resulting **ID token**
as `Authorization: Bearer` (ADR-19 §4).

### The bug (found by BVA on staging, 2026-06-18)

The SPA app client grants read access to `custom:tenant_id`
(`read_attributes` in `cognito.tf`). That is **necessary but not sufficient**:
the Cognito Hosted-UI / OAuth2 (PKCE) flow does **not** place a custom attribute
into the ID token on read access alone. A live PKCE login produced an `id_token`
with correct `aud` / `iss` / `email` but **no** `custom:tenant_id`, and the
gateway rejected every real login with `Unauthenticated: missing tenant id
claim`.

The asymmetry that hid this: the non-OAuth `InitiateAuth` / SRP API flows *do*
return custom attributes in the ID token, so any test that authenticated through
the SDK rather than the Hosted UI passed. The bug only surfaces on the real
browser PKCE path. AWS's documented way to add a custom claim to an
OAuth-flow token is a pre-token-generation Lambda — read permission governs
*visibility of the attribute*, not *its presence in an OAuth token*
([Pre token generation Lambda trigger](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-pre-token-generation.html)).

### The shipped fix (current state)

PR #101 (merged) added a **Pre-Token-Generation Lambda (V1)**
(`terraform/envs/platform/cognito-lambda.tf`, source
`lambda/pretoken/index.mjs`, wired via the pool's `lambda_config` in
`cognito.tf`). It copies the user's `custom:tenant_id` attribute into the ID
token via `claimsOverrideDetails.claimsToAddOrOverride`. Proven live: after the
deploy, a real PKCE token carried `custom:tenant_id=t-demo` and the gateway
authorized the call through to the engine.

### The question this ADR answers

Bin wants to evaluate moving **off** the Lambda for prod to shrink the
operational surface (a Lambda on the auth hot path = cold starts, an IAM exec
role, an extra deploy artifact). The honest test: does a cleaner option genuinely
win, or is the Lambda the canonical AWS mechanism and the right thing to keep?

## Grounding: what Cognito actually does

From the AWS pre-token-generation docs
([reference](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-pre-token-generation.html)),
the claim/version matrix that drives the decision:

- A `custom:` attribute is an **ID-token** claim. It is `Can add? Yes` via
  `claimsToAddOrOverride` in **all** trigger event versions (V1/V2/V3).
- The **V1 (Basic features)** trigger customizes **the ID token only**, and is
  available on **all tiers including Lite** (the current pool's tier — no paid
  upgrade).
- **Access-token** claim customization requires the **V2 / V3** trigger, which is
  available **only on the Essentials or Plus feature plan** — a paid tier
  ($0.015 / MAU after a 10,000-MAU free allowance,
  [Cognito pricing](https://aws.amazon.com/cognito/pricing/)).
- `cognito:groups` is a **default claim in BOTH the ID and access tokens**, with
  **no Lambda required**
  ([access token](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-access-token.html)).
- There is **no config-only / "managed login"** switch that injects an arbitrary
  custom claim without a Lambda. The Essentials "access token customization"
  feature *is* the pre-token-generation Lambda (V2) — the feature plan unlocks
  the trigger version, it does not replace the Lambda
  ([Essentials plan features](https://docs.aws.amazon.com/cognito/latest/developerguide/feature-plans-features-essentials.html)).

## Options

### Option 1 — Keep the Pre-Token-Generation Lambda (V1) — current

The pool's `lambda_config.pre_token_generation` points at a Node.js V1 Lambda
that copies `custom:tenant_id` into the ID token.

**Pros**
- This is **AWS's documented mechanism** for adding a custom claim to an
  OAuth-flow token
  ([pre-token docs](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-pre-token-generation.html)).
- Works on the **current (Lite/Basic) tier** — V1 customizes the ID token with
  no paid feature-plan upgrade.
- **Zero gateway change.** The gateway already validates the ID token and reads
  `custom:tenant_id`. No frontend change.
- **Proven live** on staging end-to-end (PKCE → `custom:tenant_id=t-demo` →
  engine).
- Tenant id stays a **first-class string attribute** on the user — clean
  semantics, admin-assignable, not overloaded onto an authz primitive.

**Cons**
- A Lambda on the auth hot path: a cold start adds latency to token issuance
  (mitigated — token issuance is once per session, not per request; the gateway
  caches nothing from the Lambda).
- One more deploy artifact (zip, `archive_file`) + an IAM exec role
  (`AWSLambdaBasicExecutionRole`) to own and patch (runtime EOL upgrades).
- Per-pool wiring — see the multi-region note below.

### Option 2 — Model tenant as a Cognito group (`cognito:groups`)

Create one Cognito group per tenant; `cognito:groups` is natively present in both
tokens, so no Lambda. The gateway changes to read `cognito:groups` instead of
`custom:tenant_id`.

**Pros**
- **No Lambda** — removes the hot-path function, the exec role, and the deploy
  artifact.
- `cognito:groups` travels in **both ID and access tokens** with no
  customization
  ([access token](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-access-token.html)),
  so it also satisfies option 4 (access-token validation) for free.
- Groups are a first-class Cognito object — admin-manageable, IaC-able.

**Cons**
- **Semantic stretch.** Groups are a *coarse role / authz* primitive (they carry
  IAM-role mapping, `precedence`, `cognito:preferred_role`). Reusing them as a
  *tenant identifier* overloads an authz concept onto an identity concept.
- **`cognito:groups` is an ARRAY**, not a scalar. A user in multiple groups
  yields `["t-acme","admins"]`. The gateway must define "which element is the
  tenant" — a naming convention (e.g. `t-` prefix) or a separate
  group-naming-namespace constraint. Today's contract is a single scalar tenant;
  this introduces multiple-group ambiguity the code must now resolve and test
  (BVA: 0, 1, 2+ groups).
- **Group name == tenant id** becomes a hard constraint; group names have their
  own charset/length rules distinct from a 256-char string attribute.
- **Limits:** up to 10,000 groups per pool and a user in up to 100 groups
  ([quotas](https://docs.aws.amazon.com/cognito/latest/developerguide/quotas.html)).
  10k tenants is a real ceiling for a multi-tenant SaaS; a string attribute has
  no such tenant ceiling.
- **Gateway + user-seeding rewrite.** `OIDCProvider` must parse an array claim
  and pick the tenant; `AdminAddUserToGroup` replaces the `custom:tenant_id`
  attribute write. Net: more code, more tests, weaker semantics — to remove one
  Lambda.

### Option 3 — Cognito token customization without a Lambda (config-only)

Use Cognito "managed login" / advanced token customization to add the custom
claim by configuration, no Lambda.

**Pros**
- Would be the cleanest if it existed.

**Cons**
- **It does not exist for arbitrary custom claims.** Cognito's only mechanism to
  add a custom claim to a token is the pre-token-generation Lambda. The
  Essentials/Plus "access token customization" feature *is* that Lambda at a
  higher trigger version, not a config alternative
  ([Essentials plan features](https://docs.aws.amazon.com/cognito/latest/developerguide/feature-plans-features-essentials.html),
  [pre-token docs](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-pre-token-generation.html)).
  The native config-only claims are the standard OIDC attributes (email, name…)
  and `cognito:groups` — i.e. this option collapses into option 1 (Lambda) or
  option 2 (groups). **Rejected as non-existent.**

### Option 4 — Validate the ACCESS token (OAuth2 resource-server canonical)

The RETRO flagged ID-token validation as non-canonical: OAuth2 says the resource
server (the gateway) should authorize on the **access token**; the ID token is
for the client. Switch the gateway to validate the access token.

**Pros**
- **Canonically correct** OAuth2 — the access token is the API-authorization
  token; the ID token is meant for the SPA, not the resource server
  ([access token purpose](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-access-token.html)).
- Independent signing key per token type — clean separation.

**Cons (the honest part)**
- **A `custom:` attribute is an ID-token claim. It is NOT in the access token by
  default**
  ([access token default payload](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-access-token.html)).
  To put `custom:tenant_id` into the access token you need the **V2 trigger** —
  which **requires the Essentials/Plus paid tier**
  ([pre-token docs](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-pre-token-generation.html)).
- So this option **does not remove the Lambda — it relocates it from V1 to V2 and
  adds a paid tier upgrade**. It costs more (Essentials MAU pricing) and keeps the
  hot-path function. It is *more correct* but *strictly more operational surface*,
  the opposite of the stated goal.
- It also forces a frontend change (send the access token, not the ID token) and
  a gateway audience-semantics change (access-token `aud`/`client_id` differ from
  ID-token `aud`).
- **Exception:** if the gateway switched to authorize on **`cognito:groups`**
  (option 2), the access token *already* carries it with no Lambda — option 4
  becomes Lambda-free, but only by inheriting all of option 2's semantic costs.

## Decision

**Keep the Pre-Token-Generation Lambda (Option 1).**

It is AWS's documented and canonical mechanism for adding a custom claim to an
OAuth-flow token, it runs on the current tier with no paid upgrade, it is already
proven live end-to-end, and it requires **zero** gateway / frontend / user-seeding
change. Every Lambda-free alternative is worse:

- **Option 3 doesn't exist** — config-only custom claims aren't a Cognito feature.
- **Option 4 doesn't remove the Lambda** — it moves it to V2 and adds the
  Essentials paid tier; more surface, more cost, for a correctness purity that
  buys nothing here (the gateway validates iss/aud/exp/signature on the ID token
  exactly as it would on the access token).
- **Option 2 (groups) is the only genuinely Lambda-free path, but it pays for
  that by overloading a coarse authz primitive as a tenant id**: an array claim
  with multiple-group ambiguity, a 10k-tenant ceiling, group-name == tenant-id
  constraints, and a gateway + seeding rewrite. That is more code and weaker
  semantics to delete one well-understood, low-risk Lambda.

The Lambda's cost is small and bounded: it fires once per token issuance (per
session, not per request), it carries only `AWSLambdaBasicExecutionRole`, and the
function body is 16 lines with no external calls. The operational surface it adds
is far cheaper than the semantic debt option 2 would create.

### Scoreboard

| Option | Lambda-free? | Tier | Gateway change | Frontend change | Semantics | Verdict |
|---|---|---|---|---|---|---|
| **1. Pre-Token Lambda V1 (current)** | No | Lite/Basic (no upgrade) | None | None | Clean (scalar attr) | **CHOSEN** |
| 2. `cognito:groups` | **Yes** | Lite/Basic | Rewrite (array parse) | None | Stretched (authz overload, 10k cap) | Rejected — semantic debt |
| 3. Config-only, no Lambda | — | — | — | — | — | Rejected — does not exist |
| 4. Validate access token | No (needs V2) | **Essentials (paid)** | Yes (token + aud) | Yes (send access tok) | Canonical but pricier | Rejected — more surface, more cost |

## Consequences

- The gateway keeps validating the **ID token** and reading `custom:tenant_id` —
  no `aegis-core` code change. The RETRO's "ID-token validation is non-canonical"
  note is acknowledged and consciously accepted: the gateway fully verifies
  signature + iss + aud + exp on the ID token, so the security properties match an
  access-token check; the canonical-purity gain does not justify the paid tier +
  Lambda-relocation cost.
- One Lambda + IAM exec role per pool remains a managed artifact. Owner action on
  Node.js runtime EOL: bump `runtime` in `cognito-lambda.tf` (currently
  `nodejs20.x`).
- `read_attributes` on the SPA client stays as-is — still required so the
  attribute is readable; the Lambda is what injects it into the OAuth token.
- If the product ever needs **access-token-based authorization** (e.g. a separate
  resource server, M2M client-credentials with `aws.cognito.signin.user.admin`),
  revisit option 4 + Essentials at that point — that's a real driver; "OAuth
  purity" alone is not.

## Multi-region / multi-pool note (prod is dual-region)

Prod is dual-region (eu-central-1 + eu-west-1) with **one user pool per account**;
`cognito.tf` applies once per cluster account, so staging and prod get separate
pools naturally (the `aegis-core-${var.environment}` name already encodes this).

The Lambda is **per-pool configuration** (`lambda_config` lives on the pool
resource), so each pool needs its own Lambda + exec role + invoke permission. This
is already handled by the IaC shape: `cognito-lambda.tf` is part of the per-env
`platform` apply, so each account's apply provisions its own copy — no manual
cross-region replication. If prod ever runs two pools in one account across both
regions (it does not today), the Lambda + permission would need to be replicated
per pool/region; the current "one pool per account" model means one Lambda per
account.

Contrast: had we chosen **groups** (option 2), groups are also per-pool objects
created with the pool, so they would likewise need per-pool seeding — groups do
**not** travel across pools/accounts automatically. So the multi-region replication
burden is comparable between option 1 and option 2; it is not a tie-breaker.

## Prod rollout note (what would change if the option were NOT the current one)

The decision is to keep the current option, so **no migration is required for
prod** — the existing `cognito-lambda.tf` rides the per-account prod apply
unchanged. Recorded for completeness, had a different option won:

- **If option 2 (groups):** gateway `OIDCProvider` rewritten to parse the
  `cognito:groups` array and select the tenant by convention (with BVA tests for
  0 / 1 / 2+ groups); `TenantIDClaim` default changed; user-seeding switched from
  a `custom:tenant_id` attribute write to `AdminAddUserToGroup`; one Cognito group
  per tenant created in IaC; `cognito-lambda.tf` deleted.
- **If option 4 (access token):** user pool feature plan upgraded to Essentials
  (paid); the pre-token Lambda upgraded V1 → V2 (`pre_token_generation_config` /
  `LambdaVersion = V2_0`) to inject `custom:tenant_id` into the access token;
  frontend changed to send the **access token** as the Bearer; gateway audience
  handling adjusted for the access token's `client_id`/`aud` shape.

## References

- [Pre token generation Lambda trigger — Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/user-pool-lambda-pre-token-generation.html) (V1/V2/V3, claim matrix, `custom:` is ID-token, tier gating)
- [Essentials plan features — Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/feature-plans-features-essentials.html) (access-token customization = V2 Lambda + paid tier)
- [Understanding the access token — Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-access-token.html) (default payload; `cognito:groups` native in access token)
- [Understanding the identity (ID) token — Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/amazon-cognito-user-pools-using-the-id-token.html)
- [Quotas in Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/quotas.html) (10,000 groups/pool; 100 groups/user)
- [Amazon Cognito pricing](https://aws.amazon.com/cognito/pricing/) (Essentials $0.015/MAU)
- [Adding groups to a user pool — Amazon Cognito](https://docs.aws.amazon.com/cognito/latest/developerguide/cognito-user-pools-user-groups.html) (group precedence, role mapping)
- ADR-19 — `docs/adr/19-aws-public-edge-domain-acm-cognito.md` (the Cognito edge decision; §4 gateway-terminates-auth)
