#!/usr/bin/env python3
"""Hand-frame an improbable-eng grpc-web request to aegis.v1.Gateway/ListCorpora
and print the grpc-status the Gateway returns.

The aegis Gateway speaks improbable-eng grpc-web (content-type
`application/grpc-web+proto`) — NOT native gRPC, NOT Connect. grpcurl and plain
JSON both 404 against it. We frame the request ourselves (5-byte prefix + protobuf
body) and read the grpc-status, which improbable-eng returns either as HTTP
response headers (trailers-only, when there is no data frame) or as a trailer
frame in the body (flag bit 0x80). This script handles both.

The OIDC interceptor authenticates BEFORE the handler runs and maps any auth
failure to grpc-status 16 (Unauthenticated). So the negative faces never need a
valid body — an empty ListCorporaRequest (tenant_id="") is sufficient.

Usage (CLI):
    python3 grpcweb.py [--host HOST] [--port PORT] <case> [token]

    HOST defaults to aegis-core-gateway.aegis-core.svc.cluster.local (in-cluster DNS).
    PORT defaults to 8080.

    When run via laptop port-forward, pass --host localhost and the forwarded port.

    case in {notoken, garbage, malformed, tampered, valid}
      notoken    -- no authorization header
      garbage    -- `Bearer garbage`
      malformed  -- `Bearer aaa.bbb.ccc`
      tampered   -- `Bearer <token>` (caller supplies a sig-tampered JWT)
      valid      -- `Bearer <token>` (caller supplies a real id_token)

Import API:
    from grpcweb import frame, run, tamper
"""
import argparse
import socket
import struct
import sys


# ── Constants ──────────────────────────────────────────────────────────────────
DEFAULT_HOST = "aegis-core-gateway.aegis-core.svc.cluster.local"
DEFAULT_PORT = 8080
_PATH = "/aegis.v1.Gateway/ListCorpora"


# ── Protocol helpers ───────────────────────────────────────────────────────────

def frame(msg: bytes) -> bytes:
    """Wrap msg in a grpc-web data frame: 1 flag byte (0x00) + 4-byte big-endian length."""
    return struct.pack(">BI", 0, len(msg)) + msg


def build_http(host: str, path: str, body: bytes, token: "str | None") -> bytes:
    headers = [
        f"POST {path} HTTP/1.1",
        f"Host: {host}",
        "Content-Type: application/grpc-web+proto",
        "X-Grpc-Web: 1",
        "Accept: application/grpc-web+proto",
        f"Content-Length: {len(body)}",
        "Connection: close",
    ]
    if token is not None:
        headers.append(f"authorization: {token}")
    return ("\r\n".join(headers) + "\r\n\r\n").encode() + body


def dechunk(data: bytes) -> bytes:
    out = b""
    i = 0
    while i < len(data):
        j = data.find(b"\r\n", i)
        if j < 0:
            break
        try:
            size = int(data[i:j], 16)
        except ValueError:
            break
        if size == 0:
            break
        out += data[j + 2 : j + 2 + size]
        i = j + 2 + size + 2
    return out


def parse_trailer_frames(body: bytes) -> "tuple[dict, list]":
    out: dict = {}
    flags: list = []
    i = 0
    while i + 5 <= len(body):
        flag = body[i]
        length = struct.unpack(">I", body[i + 1 : i + 5])[0]
        payload = body[i + 5 : i + 5 + length]
        flags.append(flag)
        if flag & 0x80:  # grpc-web trailer frame
            for line in payload.split(b"\r\n"):
                if b":" in line:
                    k, v = line.split(b":", 1)
                    out[k.decode().strip().lower()] = v.decode().strip()
        i += 5 + length
    return out, flags


# ── Core transport ─────────────────────────────────────────────────────────────

def run(
    host: str,
    port: int,
    body: bytes,
    token: "str | None",
    path: str = _PATH,
    timeout: int = 30,
) -> "tuple[str, dict, dict, list]":
    """Send one grpc-web request and return (status_line, http_headers, grpc_trailers, frame_flags).

    Parameters
    ----------
    host:    Target host (IP or DNS name reachable from the caller).
    port:    TCP port.
    body:    Already-framed grpc-web body (call frame() first).
    token:   Full authorization header value (e.g. ``"Bearer <jwt>"``) or None.
    path:    gRPC method path (default /aegis.v1.Gateway/ListCorpora).
    timeout: Socket connect/read timeout in seconds.
    """
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.sendall(build_http(host, path, body, token))
    data = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
    sock.close()

    sep = data.find(b"\r\n\r\n")
    head = data[:sep].decode(errors="replace")
    rest = data[sep + 4 :]
    status_line = head.split("\r\n")[0]
    hdrs: dict = {}
    for line in head.split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            hdrs[k.strip().lower()] = v.strip()
    if hdrs.get("transfer-encoding", "").lower() == "chunked":
        rest = dechunk(rest)
    trailers, flags = parse_trailer_frames(rest)
    return status_line, hdrs, trailers, flags


# ── JWT tamper helper ──────────────────────────────────────────────────────────

def tamper(token: str) -> str:
    """Return a copy of *token* with the last byte of the signature segment flipped.

    A tampered token passes JWT structural validation (three dot-separated
    base64url segments) but fails signature verification — the Gateway's OIDC
    middleware must reject it with grpc-status 16 (BVA tampered face).

    Raises ValueError if *token* is not a three-part JWT or has an empty
    signature segment. Only real id_tokens (e.g. from cognito_pkce.py) should
    be passed here; passing a BVA fixture string (``"garbage"``) is a caller bug.
    """
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError(
            f"tamper(): expected a three-part JWT, got {len(parts)} parts. "
            "Pass a real id_token, not a test fixture."
        )
    sig = parts[2]
    if not sig:
        raise ValueError("tamper(): JWT has an empty signature segment.")
    # Flip the last character between 'A' and 'B' — both are valid base64url
    # characters, so the token remains structurally valid but the signature
    # no longer matches.
    flipped = "A" if sig[-1] != "A" else "B"
    return parts[0] + "." + parts[1] + "." + sig[:-1] + flipped


# ── CLI entry point ────────────────────────────────────────────────────────────

def _build_token(case: str, extra: "str | None") -> "str | None":
    fixed = {
        "notoken": None,
        "garbage": "Bearer garbage",
        "malformed": "Bearer aaa.bbb.ccc",
    }
    if case in fixed:
        return fixed[case]
    if case in ("tampered", "valid"):
        if not extra:
            print(f"ERROR: case '{case}' requires a token argument.", file=sys.stderr)
            sys.exit(1)
        return "Bearer " + extra
    # argparse choices= already guards this branch; defensive only.
    print(f"ERROR: unknown case '{case}'.", file=sys.stderr)
    sys.exit(1)


def main(argv: "list[str] | None" = None) -> None:
    parser = argparse.ArgumentParser(
        description="Hand-frame a grpc-web BVA probe to the aegis Gateway."
    )
    parser.add_argument(
        "--host",
        default=DEFAULT_HOST,
        help=(
            f"Gateway host (default: {DEFAULT_HOST}). "
            "For laptop port-forward use --host localhost."
        ),
    )
    parser.add_argument(
        "--port",
        type=int,
        default=DEFAULT_PORT,
        help=f"Gateway port (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "case",
        choices=["notoken", "garbage", "malformed", "tampered", "valid"],
        help="BVA test case",
    )
    parser.add_argument(
        "token",
        nargs="?",
        default=None,
        help="JWT token string — required for 'tampered' and 'valid'",
    )
    args = parser.parse_args(argv)

    token = _build_token(args.case, args.token)
    body = frame(b"")  # empty ListCorporaRequest is valid (tenant_id="")
    sl, hdrs, trailers, flags = run(args.host, args.port, body, token)

    gs = trailers.get("grpc-status") or hdrs.get("grpc-status")
    gm = trailers.get("grpc-message") or hdrs.get("grpc-message")
    print(f"HTTP={sl}")
    print(f"content-type={hdrs.get('content-type')}")
    print(f"grpc-status={gs}  grpc-message={gm}")
    print(f"num_frames={len(flags)} flags={[hex(f) for f in flags]}")


if __name__ == "__main__":
    main()
