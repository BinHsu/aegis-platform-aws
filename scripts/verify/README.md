# scripts/verify — aegis-core verification harness

Three-tier verification harness for the aegis-core dual-region deployment. Each tier
is independent and progressively deeper.

| Tier | Script | Needs cluster? | Needs AWS creds? | Cost |
|------|--------|----------------|-------------------|------|
| 0 — Static | `static-checks.sh` | No | No | $0 |
| 1 — AWS API | `aws-api-checks.sh` | No | Yes (SSO) | $0 |
| 2 — In-cluster | `run-incluster-verify.sh` | Yes | Yes (SSO) | ~$0.01/run |

---

## Tier 0 — Static checks (`static-checks.sh`)

Cluster-free, cost-free. Safe on every PR and local iteration.

| Check | What | Tool |
|-------|------|------|
| 1 | `terraform validate` (bootstrap / platform / regional) | terraform |
| 2 | `terraform test` — mock-only cold-start gate (ADR-21 §D.2) | terraform |
| 3 | Crossplane render + schema validate (XBucket XRD/Composition, ADR-22) | crossplane CLI + helm |
| 4 | `kyverno test` — aegis-policies ClusterPolicy unit tests | kyverno CLI |
| 5 | `kustomize build` — aegis-core-deploy overlays | kustomize + CORE_DEPLOY_DIR |

```bash
BIN=./bin \
CORE_DEPLOY_DIR=/path/to/aegis-core-deploy \
./scripts/verify/static-checks.sh
```

**Cross-repo dependency (Check 5):** deploy overlays live in `aegis-core-deploy`, not here.
Set `CORE_DEPLOY_DIR` to a local clone. The check skips cleanly (SKIP, not FAIL) if unset.

**Kyverno test (Check 4):** the `aegis-policies` chart has no `tests/` directory yet — the
`kyverno test` authoring is explicitly marked "E2E PENDING platform bootstrap" in the chart.
The check skips with a clear message.

---

## Tier 1 — AWS-API checks (`aws-api-checks.sh`)

No cluster access needed. Uses AWS CLI calls only.

| Check | Assertion |
|-------|-----------|
| 1 | ECR `describe-images` — both regions have at least one image tag |
| 2 | EKS `list-pod-identity-associations` — engine + populator assoc present; engine IAM role has no OIDC trust (no IRSA) |
| 3 | ACM `describe-certificate` — status ISSUED in both regions |
| 4 | S3 `head-bucket` — model bucket + XBucket scratch bucket in both regions |
| 5 | IAM `simulate-principal-policy` — engine role may `s3:GetObject` on its model bucket |
| 6 | Route 53 — ≥2 A records with distinct `SetIdentifier` + non-null `Region` (latency/failover policy); reversible failover sim when `SIMULATE_FAILOVER=true` |

```bash
PROFILE=aegis-staging-admin \
PRIMARY_REGION=eu-central-1 SECONDARY_REGION=eu-west-1 \
PLATFORM_TF_DIR=/path/to/terraform/envs/platform \
PRIMARY_REGIONAL_TF_DIR=/path/to/terraform/envs/regional \
SECONDARY_REGIONAL_TF_DIR=/path/to/terraform/envs/regional \
./scripts/verify/aws-api-checks.sh
```

All resource names and ARNs are derived from `terraform output`. Override any variable
explicitly (e.g. `ZONE_ID`, `ACM_ARN_P`, `ENGINE_ROLE_P`) for faster iteration
without a full Terraform init.

**Failover simulation (Check 6b):** opt-in only (`SIMULATE_FAILOVER=true`). It briefly
disables the primary health check, queries `test-dns-answer`, then re-enables it.
This touches live Route 53 state — do not run against prod without intent.

---

## Tier 2 — In-cluster verifier Job (`run-incluster-verify.sh`) — **DEFAULT**

**This is the default verification path for unattended/headless runs (#145).** It
runs grpcurl/BVA/PKCE from a Job *inside* the cluster over service DNS — zero
`kubectl port-forward`, zero `kill`/`pkill`. The laptop port-forward path below is
now the explicitly-requested **interactive fallback**, not the default: its
cleanup needs a `kill` (macOS has no `timeout`), and the kill-guard PreToolUse
hook prompts on any kill/pkill — so it cannot run headless.

Deploys a Job inside the `aegis-core` namespace that reaches services over cluster DNS.

| Face | What |
|------|------|
| F2 | Transcription — `grpcurl StreamTranscribe` with PCM fixture, checks `TranscriptSegment.text` |
| F3 | OIDC BVA — 5 faces: notoken/garbage/malformed → grpc-status 16; tampered → 16; valid → non-16 |
| F6 | RAG-reachable — `ListCorpora` with valid token reaches the handler (non-16) |
| F7 | Populator-done — model bucket is non-empty (`s3api list-objects-v2`) |
| F8 | Tenant isolation — two tenant tokens authenticate independently |

```bash
PROFILE=aegis-staging-admin \
PRIMARY_CTX=eu-central-1 SECONDARY_CTX=eu-west-1 \
PLATFORM_TF_DIR=/path/to/terraform/envs/platform \
./scripts/verify/run-incluster-verify.sh
```

`VERIFY_IMAGE` now **defaults** to the pre-built published image
`ghcr.io/binhsu/aegis-verify:latest` — an unattended run never builds an image ad
hoc. Override it only for a private registry (e.g. deployment ECR) or to pin a
digest. The driver applies the Job (`k8s/verifier-job.yaml`) per region via
`kubectl`, waits for `condition=complete`, fetches logs, and deletes the Job.

**The verifier image is pre-built and published — you do not build it locally.**
`.github/workflows/verifier-image.yml` builds `Dockerfile.verifier` and pushes to
GHCR (`ghcr.io/<owner>/aegis-verify`, tags `latest` + `sha-<short>`) on every push
to `main` that touches the image; on a PR it does a **build-without-push** so the
PR proves the image still builds. The push job writes the image **digest** to its
run summary — pin `VERIFY_IMAGE` to `…@sha256:<digest>` once `require-image-digest`
moves from Audit to Enforce (today it is Audit, so the `:latest` tag is admitted).

**ConfigMaps** (`aegis-proto`, `aegis-pcm-fixture`) are seeded into `aegis-core`
as part of bring-up so the Job is always ready (#145). The driver also seeds them
idempotently if you pass `PROTO=/path/to/aegis.proto` and `PCM_FIXTURE=/tmp/x.pcm`
— it never overwrites an existing ConfigMap. To seed manually instead:
```bash
kubectl create configmap aegis-proto \
  --from-file=aegis.proto=/path/to/aegis.proto -n aegis-core
kubectl create configmap aegis-pcm-fixture \
  --from-file=fixture.pcm=/tmp/x.pcm -n aegis-core
```

**Local kind smoke** (`local/kind-verifier-smoke.sh`) exercises the unattended
plumbing end-to-end on a throwaway kind cluster — build → `kind load` → seed
ConfigMaps → apply the real Job → assert the entrypoint runs to its summary table
in-cluster, with no port-forward and no kill. It does **not** run the F2–F8 faces
(those need a live aegis-core + Cognito — the real-cluster lane); it gates the
plumbing that replaces the laptop path.
```bash
./scripts/verify/local/kind-verifier-smoke.sh
```

---

## Laptop port-forward tier (`ws4-app-functional-e2e.sh`) — interactive fallback only

**Explicitly-requested fallback, not the default (#145).** Retained for interactive
debugging and one-shot validation from a developer laptop. It uses `kubectl
port-forward` whose cleanup needs `kill`, so it is **unusable unattended/headless**
— use Tier 2 (above) for CI and all automated verification.

Changes vs. the original harness:

- **No more scattergun `pkill`** — each port-forward PID is tracked in an array
  and killed individually in the `EXIT` trap only.
- **No fixed `sleep 5/6`** — replaced with a TCP-readiness probe (`wait_for_port`)
  with a 20-second timeout (`PF_TIMEOUT`).
- **Ephemeral ports** — `free_port()` allocates dynamically; no hardcoded 8080/8081.
- **Terraform-derived Cognito config** — set `PLATFORM_TF_DIR` and `POOL`/`CLIENT_ID`/
  `COGNITO_DOMAIN` are read from `terraform output` automatically.
- **`grpcweb.tamper()`** — token tampering is now handled by the `grpcweb` module's
  `tamper()` helper instead of an inline Python one-liner; error handling included.

```bash
PROFILE=aegis-staging-admin \
PRIMARY_CTX=eu-central-1 SECONDARY_CTX=eu-west-1 \
PLATFORM_TF_DIR=/path/to/terraform/envs/platform \
PROTO=/path/to/aegis.proto PROTO_IMPORT=/path/to/proto \
PCM_FIXTURE=/tmp/x.pcm \
./scripts/verify/ws4-app-functional-e2e.sh
```

---

## Irreducibly-human steps

These steps cannot be scripted and must be performed by a human operator:

1. **AWS SSO login** — `aws sso login --profile <profile>` must succeed before any tier runs.
2. **Cloudflare NS delegation** — the Route 53 hosted zone NS records must be added to
   Cloudflare (or the registrar) for ACM DNS validation and external-dns to work. This is a
   one-time operator action per environment account.
3. **GitHub Environment approval** — `infra-apply.yml` is gated on the `production` GitHub
   Environment which requires manual approval. CI cannot self-approve.
4. **Model population** — the model bucket in each region must be seeded by the operator
   (`aegis-core-model-populator` Job) before F7 (populator-done) can pass.
5. ~~**Verifier image push**~~ — **now automated (#145).** `.github/workflows/verifier-image.yml`
   builds and publishes `aegis-verify` to GHCR on push to `main`; nodes pull the public image
   with no cloud creds. Only needed manually if you target a private registry the workflow does
   not publish to (e.g. a locked-down deployment ECR) — then push it there and set `VERIFY_IMAGE`.

---

## Helper modules

| File | Purpose |
|------|---------|
| `grpcweb.py` | Hand-frames improbable-eng grpc-web requests. Importable: `frame`, `run`, `tamper`. Default host = in-cluster DNS. |
| `cognito_pkce.py` | Drives Cognito Hosted-UI PKCE flow; writes `id_token` to a file. |
| `in-cluster-verify.py` | Python runner for the Tier 2 Job (F2–F8 faces). |
| `Dockerfile.verifier` | Builds the verifier image (grpcurl + python3 + helpers). |
| `k8s/verifier-job.yaml` | Kubernetes Job template (envsubst variables). |
