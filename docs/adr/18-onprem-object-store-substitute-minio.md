# ADR-18: on-prem object-store substitute — MinIO for the engine model store (WS2-2)

## Status

Accepted. Repo work (the `components/onprem-binding` MinIO slice) done
2026-06-16. Live local-Talos proof tracked in the WS2-2 section below / issue #46.

## Context

WS1 (ADR-17) made `aegis-core-deploy`'s base provider-neutral and proved the
release pipeline + injection contract on local Talos, but stopped short of a
fully-serving core: identity, object storage, and gateway auth substitutes were
explicitly deferred to WS2. This ADR covers the **object-store axis** — the
first WS2 slice.

On AWS the engine's model store is an S3 bucket (`aegis-staging-models-*`)
surfaced into the pod at `/models` via a Mountpoint-S3 CSI mount (ADR-0026 in
`aegis-core`; the AWS-side CI populator is itself still deferred, ldz #85). The
on-prem target has no S3. WS2-2 builds the substitute.

### The load-bearing finding: the engine has no S3 client

Reading the `aegis-core` engine source settled the slice's whole shape:

- The engine binary contains **zero** in-process object-store code — no AWS SDK,
  no S3 client, no endpoint config. It reads model files from a local POSIX path
  and never makes a network call for them
  (`engine_cpp/src/models/manifest_loader.{h,cc}`).
- Model resolution is content-addressed: `$AEGIS_MODEL_PATH/<id>/<sha256>.<ext>`.
  At startup, before the gRPC server binds, the engine walks every
  `required: true` entry in `models/manifest.json` (bundled in the image) and
  verifies each file's existence, size, and SHA-256. **Any miss is fatal**
  (`main.cc:106-117`).
- Exactly **one** model is `required: true` today — `whisper-tiny-en` (~75 MB).
  `bge-m3` (the RAG embedder, 438 MB) is `required: false`: the engine
  graceful-degrades to transcript-only when it is absent. So the engine boots
  once `/models` holds a single 75 MB object.

The consequence: **there is no S3 endpoint to repoint at MinIO.** The AWS↔on-prem
difference is entirely in *how `/models` gets populated*, not in how the engine
reads it. The substitution lives at the volume-delivery layer.

## Decision

### MinIO is the object store; an init-container is the "CSI mount"

A new kustomize Component, `k8s/components/onprem-binding`, included only by
`overlays/talos` — the mirror of `components/aws-binding` (ADR-17: every target
= neutral base + its binding component). The object-store axis adds:

- **MinIO** (Deployment + Service + Secret) — an S3-compatible store, single
  replica, ephemeral `emptyDir` backing (durability is not a goal on an
  ephemeral dev cluster; the bootstrap re-seeds idempotently after a restart).
- **A bootstrap Job** — the on-prem analogue of the AWS CI populator. A `curl`
  init-container fetches `whisper-tiny-en` from its upstream origin and verifies
  the manifest SHA-256 (the integrity anchor: we fetch from a moving ref but
  pin content by hash, so a changed upstream fails loudly here, not at engine
  preflight). An `mc` container uploads it into the bucket at the CAS key
  `<id>/<sha256>.<ext>`.
- **A `model-fetch` init-container** on the engine Rollout and the seed Job —
  the analogue of the CSI mount. It waits for the required object to land in
  MinIO, then `mc mirror`s the bucket into the pod's `/models` `emptyDir`
  before the engine container runs its CAS preflight. Same `/models` contract
  the CSI mount would satisfy; the engine cannot tell the difference.

The Component patches are JSON6902 (`op: add`), not strategic merge — kustomize
has no openapi schema for the Argo Rollout CRD, so a merge patch would clobber
the container list; `add` precisely appends the init-container and the
NetworkPolicy egress rule.

### Base correction: `AEGIS_MODEL_PATH` is a directory, not a file

The base engine Rollout and seed Job set `AEGIS_MODEL_PATH=/models/ggml-tiny.en.bin`
— a single file path, stale from the pre-CAS engine. The current engine treats
`AEGIS_MODEL_PATH` as the CAS *root directory* (`<root>/<id>/<sha>.<ext>`), so
the old value made it look under `/models/ggml-tiny.en.bin/<id>/…` and fail.
Corrected to `/models` in the base (applies to every target — it is the real
engine contract, not an on-prem concern). `AEGIS_MANIFEST_PATH` keeps its
in-image default. staging/prod still render (their model delivery stays the
deferred placeholder); the change is a one-line correctness fix, not a render
regression of substance.

## Consequences / deferrals

| Item | Owner | Note |
|---|---|---|
| AWS-side model delivery (S3 bucket + Mountpoint-S3 CSI populate) | **WS3** | The aws-binding still mounts an `emptyDir` placeholder; real S3 delivery rides the bootstrap/OIDC work. |
| `bge-m3` in the bucket | optional | `required: false`; the mirror carries whatever the bucket holds. Add it to the bootstrap when RAG is exercised on-prem. |
| MinIO credentials as a real secret | **WS2-3** | The committed `minio-credentials` Secret is local-dev only (ephemeral single-tenant cluster). The identity slice (SPIRE / sealed-secret) is the natural home for real secrecy. |
| MinIO persistence (PVC instead of `emptyDir`) | on-prem prod | Ephemeral is correct for the dev substrate; the bootstrap is idempotent. |
| NetworkPolicy enforcement | substrate | The local Talos CNI (flannel) does not enforce NetworkPolicy; the egress/ingress rules are authored for fidelity and for a CNI that does. |

## WS2-2 live proof (local Talos, 2026-06-16)

Proven end-to-end on a single-node Talos cluster (apple/container, arm64,
4 GB), all images pulled from public GHCR:

1. **MinIO up** (the S3 substitute), Deployment Ready.
2. **Bootstrap Job** fetched `whisper-tiny-en` from upstream, SHA-verified, and
   loaded it into the bucket at the CAS key
   `whisper-tiny-en/921e4cf8…20b1f.bin` (74 MiB).
3. **model-fetch init-container** mirrored the bucket into the engine pod's
   `/models` emptyDir, producing `/models/whisper-tiny-en/921e4cf8…20b1f.bin`
   at **77704715 bytes — exactly the manifest `size_bytes`.** The object-store
   substitution (S3 → MinIO, CSI-mount → init-container) is proven at the
   delivery layer: byte-exact CAS file, same contract the engine reads.
4. **Engine boots + serves**: CAS preflight passed against the MinIO-delivered
   model (`model: whisper-tiny-en = 77704715 bytes`, `model_path=/models/...`),
   `listening on 0.0.0.0:50051`, pod 1/1 Running, 0 restarts, gRPC port reachable
   in-cluster. `bge-m3` (required=false, not in the bucket) graceful-degraded to
   "RAG hints disabled" — by design, not a failure.

This was the **first time the engine ran on any substrate.** WS2-1 had only
proved it builds; running it surfaced five engine-image packaging gaps, all
fixed in `aegis-core` (PR #147) before this proof passed:

| # | Symptom | Fix |
|---|---|---|
| 1 | `exec … no such file or directory` | distroless `static` → `cc` (dynamic binary needs a loader + libstdc++) |
| 2 | `GLIBC_2.38 not found` | `cc-debian12` → `cc-debian13` (runtime glibc must be ≥ the build-runner glibc) |
| 3 | `cannot load manifest` | bundle `models/manifest.json` in the image, set `AEGIS_MANIFEST_PATH` |
| 4 | *(engine runs, reads /models)* | — |
| 5 | exit 132 SIGILL | `GGML_NATIVE=OFF` (don't bake the CI runner's ARM microarch into an image run on Apple Silicon) |

Detail lives in `aegis-core` ADR-0025 + the BUILD/CI comments; the rule extracted
is "runtime-base glibc ≥ build glibc, never `-mcpu=native` for a portable image".

## References

- ADR-16 (provider-neutral injection contract, WS0), ADR-17 (core release
  parity + neutral base, WS1 — the binding-component pattern this mirrors).
- `aegis-core` ADR-0026 (content-addressable model storage), `manifest_loader.{h,cc}`,
  `models/manifest.json`.
- `aegis-core-deploy` branch `ws2/onprem-minio`
  (`k8s/components/onprem-binding`).
- WS2 epic: `aegis-platform-aws` issue #46 (`post-612-roadmap`).
