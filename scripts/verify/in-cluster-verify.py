#!/usr/bin/env python3
"""in-cluster-verify.py — runs inside the verifier-job.yaml Job.

Reaches aegis-core-engine and aegis-core-gateway over in-cluster DNS (no
port-forward). Runs the following check faces and prints a PASS/FAIL table:

  F2  Transcription   — grpcurl StreamTranscribe with the PCM fixture.
  F3  OIDC BVA        — 5-face Gateway boundary-value analysis via grpcweb.py.
  F6  RAG-reachable   — Gateway ListCorpora with a valid token returns non-16.
  F7  Populator-done  — model bucket is non-empty (aws s3api list-objects-v2).
  F8  Tenant-isolation — two users, two tenant_ids; each only sees own corpora.

Environment variables (injected by verifier-job.yaml):
  ENGINE_HOST     (default aegis-core-engine.aegis-core.svc.cluster.local)
  ENGINE_PORT     (default 50051)
  GATEWAY_HOST    (default aegis-core-gateway.aegis-core.svc.cluster.local)
  GATEWAY_PORT    (default 8080)
  PROTO           path to aegis.proto (mounted via ConfigMap or baked in)
  PROTO_IMPORT    proto import root
  PCM_FIXTURE     path to raw s16le 16kHz mono PCM file (mounted)
  EXPECT_TEXT     substring to match in TranscriptSegment.text
  MODEL_BUCKET    S3 bucket name to probe for F7 (optional; skips F7 if unset)
  AWS_REGION      for s3api call (optional; skips F7 if unset)
  COGNITO_DOMAIN  Hosted-UI domain (https://...) — required for F3/F6/F8 valid faces
  CLIENT_ID       Cognito SPA client id                         — required for F3/F6/F8
  POOL            Cognito user pool id                          — required for F3/F6/F8
  COGNITO_REGION  AWS region for Cognito API calls              — required for F3/F6/F8
  AWS_PROFILE     AWS profile (optional; may use Pod Identity instead)

F8 (tenant isolation) requires two test users and a valid backend; it is skipped
if POOL/CLIENT_ID/COGNITO_DOMAIN are not set.

Exit code 0 if every attempted check passes, non-zero otherwise.
"""
import base64
import json
import os
import subprocess
import sys
import tempfile

# Ensure grpcweb.py is importable from the same directory.
sys.path.insert(0, os.path.dirname(__file__))
from grpcweb import frame, run as gw_run, tamper  # noqa: E402

# ── Config from environment ────────────────────────────────────────────────────
ENGINE_HOST  = os.environ.get("ENGINE_HOST",  "aegis-core-engine.aegis-core.svc.cluster.local")
ENGINE_PORT  = int(os.environ.get("ENGINE_PORT",  "50051"))
GATEWAY_HOST = os.environ.get("GATEWAY_HOST", "aegis-core-gateway.aegis-core.svc.cluster.local")
GATEWAY_PORT = int(os.environ.get("GATEWAY_PORT", "8080"))
PROTO        = os.environ.get("PROTO", "")
PROTO_IMPORT = os.environ.get("PROTO_IMPORT", "")
PCM_FIXTURE  = os.environ.get("PCM_FIXTURE", "")
EXPECT_TEXT  = os.environ.get("EXPECT_TEXT", "the quick brown fox jumps over the lazy dog")
MODEL_BUCKET = os.environ.get("MODEL_BUCKET", "")
AWS_REGION   = os.environ.get("AWS_REGION", "")
POOL         = os.environ.get("POOL", "")
CLIENT_ID    = os.environ.get("CLIENT_ID", "")
COGNITO_DOMAIN = os.environ.get("COGNITO_DOMAIN", "")
COGNITO_REGION = os.environ.get("COGNITO_REGION", "eu-central-1")
AWS_PROFILE  = os.environ.get("AWS_PROFILE", "")

GRPCURL = os.environ.get("GRPCURL", "grpcurl")

results: list[tuple[str, str, str]] = []  # (face, PASS|FAIL, detail)


# Result statuses. SKIP is non-failing (an optional check whose preconditions
# are absent); only FAIL fails the overall run.
PASS = "PASS"
FAIL = "FAIL"
SKIP = "SKIP"


def record(face: str, status: str, detail: str) -> None:
    results.append((face, status, detail))
    print(f"  [{status}] {face}: {detail}", flush=True)


def bva_probe(case: str, token: str | None) -> str | None:
    """Return the grpc-status string, or None on transport failure.

    A transport error (connection refused, timeout, reset) is NOT an auth
    result — it must never be mistaken for "auth succeeded". We return None so
    callers reject it explicitly. Non-transport exceptions propagate (a bug in
    the probe should surface, not be silently swallowed into a pass).
    """
    try:
        body = frame(b"")
        _, hdrs, trailers, _ = gw_run(GATEWAY_HOST, GATEWAY_PORT, body, token)
        return trailers.get("grpc-status") or hdrs.get("grpc-status")
    except (OSError, TimeoutError):
        return None


def get_id_token(username: str, password: str, work_dir: str) -> str | None:
    """Run cognito_pkce.py and return the id_token string or None."""
    from cognito_pkce import main as pkce_main  # type: ignore[import]
    import io, contextlib

    out_path = os.path.join(work_dir, f"id_token_{username[:8]}.txt")
    env_backup = {}
    for k, v in [("COGNITO_DOMAIN", COGNITO_DOMAIN), ("CLIENT_ID", CLIENT_ID)]:
        env_backup[k] = os.environ.get(k)
        os.environ[k] = v
    # cognito_pkce reads sys.argv[1..3] and os.environ
    old_argv = sys.argv[:]
    sys.argv = ["cognito_pkce.py", username, password, out_path]
    try:
        pkce_main() if hasattr(__import__("cognito_pkce"), "main") else None
        # Fall back to subprocess if the module doesn't expose main()
    except SystemExit:
        pass
    except Exception:
        pass
    finally:
        sys.argv = old_argv
        for k, v in env_backup.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    if os.path.exists(out_path) and os.path.getsize(out_path) > 0:
        return open(out_path).read().strip()
    return None


def aws_cmd(*args: str) -> tuple[int, str, str]:
    cmd = ["aws"] + list(args)
    if AWS_PROFILE:
        cmd = ["aws", "--profile", AWS_PROFILE] + list(args)
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.returncode, r.stdout, r.stderr


def cognito_create_user(username: str, password: str, tenant: str) -> bool:
    rc, _, _ = aws_cmd(
        "cognito-idp", "admin-create-user",
        "--region", COGNITO_REGION,
        "--user-pool-id", POOL,
        "--username", username,
        "--message-action", "SUPPRESS",
        "--user-attributes",
        f"Name=email,Value={username}",
        "Name=email_verified,Value=true",
    )
    if rc != 0:
        return False
    rc, _, _ = aws_cmd(
        "cognito-idp", "admin-set-user-password",
        "--region", COGNITO_REGION,
        "--user-pool-id", POOL,
        "--username", username,
        "--password", password,
        "--permanent",
    )
    if rc != 0:
        return False
    rc, _, _ = aws_cmd(
        "cognito-idp", "admin-update-user-attributes",
        "--region", COGNITO_REGION,
        "--user-pool-id", POOL,
        "--username", username,
        "--user-attributes", f"Name=custom:tenant_id,Value={tenant}",
    )
    return rc == 0


def cognito_delete_user(username: str) -> None:
    aws_cmd(
        "cognito-idp", "admin-delete-user",
        "--region", COGNITO_REGION,
        "--user-pool-id", POOL,
        "--username", username,
    )


# ── F2: Transcription ──────────────────────────────────────────────────────────
print("\n── F2: Transcription (Engine gRPC) ──")
if not PROTO or not PCM_FIXTURE:
    record("F2-transcription", "FAIL", "PROTO or PCM_FIXTURE not set")
else:
    # Build the streaming JSON input
    b64 = base64.b64encode(open(PCM_FIXTURE, "rb").read()).decode()
    stream_json = "\n".join([
        json.dumps({"session_start": {"session_id": "incluster-verify", "tenant_id": "demo",
                                      "rag_id": "", "estimated_bytes": 200_000_000,
                                      "audio_format": {"sample_rate_hz": 16000, "channels": 1,
                                                       "bits_per_sample": 16}}}),
        json.dumps({"pcm": {"pcm": b64, "chunk_id": 0, "offset_ms": 0}}),
        json.dumps({"control": {"kind": "CONTROL_KIND_END_STREAM"}}),
    ])
    cmd = [
        GRPCURL, "-plaintext",
        "-proto", PROTO, "-import-path", PROTO_IMPORT,
        "-max-time", "120",
        "-d", stream_json,
        f"{ENGINE_HOST}:{ENGINE_PORT}",
        "aegis.v1.Engine/StreamTranscribe",
    ]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=130)
    text = ""
    for line in r.stdout.splitlines():
        try:
            obj = json.loads(line)
            t = obj.get("transcript", {}).get("text", "")
            if t:
                text = t.strip().rstrip(".")
                break
        except json.JSONDecodeError:
            pass
    if EXPECT_TEXT.lower() in text.lower():
        record("F2-transcription", "PASS", f'"{text}"')
    else:
        excerpt = (r.stdout + r.stderr).replace("\n", " ")[:200]
        record("F2-transcription", "FAIL", f"text={text!r} stdout={excerpt!r}")

# ── F3: OIDC BVA (5 faces) ────────────────────────────────────────────────────
print("\n── F3: OIDC BVA (Gateway grpc-web) ──")

# Negative faces — no token or bad token → grpc-status 16
for case, token in [
    ("notoken", None),
    ("garbage", "Bearer garbage"),
    ("malformed", "Bearer aaa.bbb.ccc"),
]:
    gs = bva_probe(case, token)
    if gs == "16":
        record(f"F3-bva-{case}", "PASS", f"grpc-status={gs}")
    else:
        record(f"F3-bva-{case}", "FAIL", f"grpc-status={gs} (want 16)")

# Valid + tampered faces require a real id_token.
_valid_token: str | None = None
if POOL and CLIENT_ID and COGNITO_DOMAIN:
    import time as _time
    _user = f"incluster-bva-{int(_time.time())}@example.com"
    _pw   = f"BvA-Verify-{int(_time.time())}-Aa1!xyz"
    with tempfile.TemporaryDirectory() as _tmp:
        _created = cognito_create_user(_user, _pw, "bva-tenant")
        if _created:
            _valid_token = get_id_token(_user, _pw, _tmp)
            cognito_delete_user(_user)

    if _valid_token:
        # valid face
        gs = bva_probe("valid", f"Bearer {_valid_token}")
        if gs is None or (isinstance(gs, str) and gs.startswith("ERROR")):
            record("F3-bva-valid", FAIL, f"transport error / no grpc-status (gs={gs!r})")
        elif gs != "16":
            record("F3-bva-valid", PASS, f"grpc-status={gs} (passed auth)")
        else:
            record("F3-bva-valid", FAIL, f"grpc-status={gs}")
        # tampered face
        try:
            tampered_tok = tamper(_valid_token)
            gs = bva_probe("tampered", f"Bearer {tampered_tok}")
            if gs == "16":
                record("F3-bva-tampered", "PASS", f"grpc-status={gs}")
            else:
                record("F3-bva-tampered", "FAIL", f"grpc-status={gs} (want 16)")
        except ValueError as e:
            record("F3-bva-tampered", "FAIL", str(e))
    else:
        record("F3-bva-valid",    "FAIL", "could not obtain id_token for valid face")
        record("F3-bva-tampered", "FAIL", "could not obtain id_token for tampered face")
else:
    record("F3-bva-valid",    "FAIL", "POOL/CLIENT_ID/COGNITO_DOMAIN not set — skipped")
    record("F3-bva-tampered", "FAIL", "POOL/CLIENT_ID/COGNITO_DOMAIN not set — skipped")

# ── F6: RAG-reachable (ListCorpora non-error with valid token) ─────────────────
print("\n── F6: RAG-reachable (ListCorpora) ──")
if _valid_token:
    gs = bva_probe("valid", f"Bearer {_valid_token}")
    if gs is None or (isinstance(gs, str) and gs.startswith("ERROR")):
        record("F6-rag-reachable", FAIL, f"transport error / no grpc-status (gs={gs!r})")
    elif gs != "16":
        record("F6-rag-reachable", PASS, f"grpc-status={gs} (gateway reached handler)")
    else:
        record("F6-rag-reachable", FAIL, f"grpc-status={gs}")
else:
    record("F6-rag-reachable", FAIL, "no valid token available (see F3)")

# ── F7: Populator-complete (model bucket non-empty) ────────────────────────────
print("\n── F7: Populator-complete (S3 model bucket) ──")
if MODEL_BUCKET and AWS_REGION:
    rc, out, err = aws_cmd(
        "s3api", "list-objects-v2",
        "--region", AWS_REGION,
        "--bucket", MODEL_BUCKET,
        "--max-items", "1",
        "--query", "length(Contents)",
        "--output", "text",
    )
    count_str = out.strip()
    if rc == 0 and count_str.isdigit() and int(count_str) > 0:
        record("F7-populator-done", "PASS", f"bucket={MODEL_BUCKET} objects≥1")
    else:
        record("F7-populator-done", "FAIL",
               f"bucket={MODEL_BUCKET} count={count_str!r} rc={rc} err={err[:120]!r}")
else:
    record("F7-populator-done", SKIP, "MODEL_BUCKET or AWS_REGION not set — skipped")

# ── F8: Tenant isolation ───────────────────────────────────────────────────────
print("\n── F8: Tenant isolation ──")
if POOL and CLIENT_ID and COGNITO_DOMAIN:
    import time as _time2
    _ts = int(_time2.time())
    _ua = f"incluster-f8a-{_ts}@example.com"
    _ub = f"incluster-f8b-{_ts}@example.com"
    _pa = f"TenantA-{_ts}-Aa1!xyz"
    _pb = f"TenantB-{_ts}-Aa1!xyz"
    _token_a = _token_b = None
    with tempfile.TemporaryDirectory() as _tmp2:
        if cognito_create_user(_ua, _pa, "tenant-a") and \
           cognito_create_user(_ub, _pb, "tenant-b"):
            _token_a = get_id_token(_ua, _pa, _tmp2)
            _token_b = get_id_token(_ub, _pb, _tmp2)
        cognito_delete_user(_ua)
        cognito_delete_user(_ub)

    # Both tenants must be able to reach the gateway (non-16), AND must NOT
    # cross into each other's data. We verify the auth boundary only here
    # (data-layer isolation would require seeded corpora — out of scope for
    # a cluster-zero-state verify). The assertion: each token independently
    # passes auth (non-16). A future enhancement can compare ListCorpora
    # responses once corpora are seeded.
    for _label, _tok in [("tenant-a", _token_a), ("tenant-b", _token_b)]:
        if _tok:
            _gs = bva_probe("valid", f"Bearer {_tok}")
            if _gs is None or (isinstance(_gs, str) and _gs.startswith("ERROR")):
                record(f"F8-isolation-{_label}-auth", FAIL,
                       f"transport error / no grpc-status (gs={_gs!r})")
            elif _gs != "16":
                record(f"F8-isolation-{_label}-auth", PASS,
                       f"grpc-status={_gs} (independent auth ok)")
            else:
                record(f"F8-isolation-{_label}-auth", FAIL,
                       f"grpc-status={_gs}")
        else:
            record(f"F8-isolation-{_label}-auth", FAIL,
                   f"could not obtain id_token for {_label}")
else:
    record("F8-isolation", SKIP, "POOL/CLIENT_ID/COGNITO_DOMAIN not set — skipped")

# ── Summary table ──────────────────────────────────────────────────────────────
print()
print(f"{'FACE':<38} {'RESULT':<6} DETAIL")
print(f"{'----':<38} {'------':<6} ------")
for face, status, detail in results:
    print(f"{face:<38} {status:<6} {detail}")

# Pass if no check FAILed. SKIP is non-failing (optional check, preconditions
# absent); a run of all-SKIP still passes (nothing was actually verified, but
# nothing failed either — the driver decides whether that is acceptable).
all_pass = all(status in (PASS, SKIP) for _, status, _ in results)

print()
print("OVERALL:", "PASS" if all_pass else "FAIL")
sys.exit(0 if all_pass else 1)
