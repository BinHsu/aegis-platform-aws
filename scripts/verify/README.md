# scripts/verify — application-functional E2E harness

`ws4-app-functional-e2e.sh` is the WS4 §7D verification harness. It proves the
aegis-core application **works** against a live dual-region deployment — not just
that Terraform applied. It runs three checks and prints a PASS/FAIL table.

| Test | What it proves | How |
|------|----------------|-----|
| 1. Transcription | model → text on the real cluster (Pod-Identity-fetched whisper-tiny-en) | Streams a PCM fixture into the internal `aegis.v1.Engine/StreamTranscribe` (native gRPC, no auth — internal service) and checks `TranscriptSegment.text`. |
| 2. OIDC BVA | the Gateway rejects bad tokens and accepts good ones | Hand-framed grpc-web calls to `aegis.v1.Gateway/ListCorpora`. Negative faces (no-token / garbage / malformed / tampered-signature) must return `grpc-status 16` (Unauthenticated); the valid face must not. |
| 3. PKCE id_token | the Cognito Hosted-UI code+PKCE flow works and the pre-token Lambda injects `custom:tenant_id` | Drives `/oauth2/authorize` → `/login` → `/oauth2/token` programmatically. The resulting id_token is TEST 2's valid face. |

## Why grpc-web, not grpcurl

The Gateway speaks **improbable-eng grpc-web** (`grpcweb.WrapServer`,
content-type `application/grpc-web+proto`) — NOT native gRPC and NOT Connect.
`grpcurl` and plain JSON both 404 against it. `grpcweb.py` frames the request
(5-byte prefix + protobuf body) and reads the `grpc-status`, which improbable-eng
returns either in HTTP response headers (trailers-only) or in a trailer frame
(flag bit `0x80`).

## Run

```bash
PROFILE=aegis-staging-admin \
PRIMARY_CTX=eu-central-1 SECONDARY_CTX=eu-west-1 \
POOL=eu-central-1_vLMT3QxOu CLIENT_ID=3tm1678cofqncgthiqjhauofjc \
COGNITO_DOMAIN=https://aegis-core-251774439261.auth.eu-central-1.amazoncognito.com \
COGNITO_REGION=eu-central-1 \
PROTO=/path/to/aegis-core/proto/aegis/v1/aegis.proto \
PROTO_IMPORT=/path/to/aegis-core/proto \
PCM_FIXTURE=/tmp/x.pcm GRPCURL=/tmp/grpcurl \
HARNESS_DIR="$(pwd)/scripts/verify" \
./scripts/verify/ws4-app-functional-e2e.sh
```

Defaults target the staging pool/client/domain; override the env vars for prod.

## Requirements

- `kubectl` with the two cluster contexts configured, `grpcurl`, `python3`, `jq`,
  `aws` CLI with a valid SSO session for `PROFILE`.
- A raw **s16le, 16 kHz, mono** PCM fixture (`PCM_FIXTURE`). The reference fixture
  says "the quick brown fox jumps over the lazy dog"; override `EXPECT_TEXT` for a
  different one.

## Cleanup

The harness deletes the Cognito test user and scrubs the captured id_token files
on exit (they are real bearer tokens). It creates no S3 buckets or objects.
