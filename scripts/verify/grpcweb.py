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

Usage:
    python3 grpcweb.py <port> <case> [token]

    case ∈ {notoken, garbage, malformed, tampered, valid}
      notoken    — no authorization header
      garbage    — `Bearer garbage`
      malformed  — `Bearer aaa.bbb.ccc`
      tampered   — `Bearer <token>` (caller supplies a sig-tampered JWT)
      valid      — `Bearer <token>` (caller supplies a real id_token)
"""
import sys, socket, struct, urllib.parse


def frame(msg: bytes) -> bytes:
    # grpc-web data frame: 1 flag byte (0x00) + 4-byte big-endian length + payload
    return struct.pack(">BI", 0, len(msg)) + msg


def build_http(host, path, body, token=None):
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
        out += data[j + 2:j + 2 + size]
        i = j + 2 + size + 2
    return out


def parse_trailer_frames(body: bytes):
    out = {}
    frames = []
    i = 0
    while i + 5 <= len(body):
        flag = body[i]
        length = struct.unpack(">I", body[i + 1:i + 5])[0]
        payload = body[i + 5:i + 5 + length]
        frames.append(flag)
        if flag & 0x80:  # grpc-web trailer frame
            for line in payload.split(b"\r\n"):
                if b":" in line:
                    k, v = line.split(b":", 1)
                    out[k.decode().strip().lower()] = v.decode().strip()
        i += 5 + length
    return out, frames


def run(host, port, path, body, token):
    sock = socket.create_connection((host, port), timeout=30)
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
    rest = data[sep + 4:]
    status_line = head.split("\r\n")[0]
    hdrs = {}
    for line in head.split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            hdrs[k.strip().lower()] = v.strip()
    if hdrs.get("transfer-encoding", "").lower() == "chunked":
        rest = dechunk(rest)
    trailers, frames = parse_trailer_frames(rest)
    return status_line, hdrs, trailers, frames


if __name__ == "__main__":
    port = int(sys.argv[1])
    case = sys.argv[2]
    token = {
        "notoken": None,
        "garbage": "Bearer garbage",
        "malformed": "Bearer aaa.bbb.ccc",
    }.get(case)
    if case in ("tampered", "valid"):
        token = "Bearer " + sys.argv[3]

    body = frame(b"")  # empty ListCorporaRequest is valid (tenant_id="")
    sl, hdrs, trailers, frames = run("localhost", port, "/aegis.v1.Gateway/ListCorpora", body, token)
    gs = trailers.get("grpc-status") or hdrs.get("grpc-status")
    gm = trailers.get("grpc-message") or hdrs.get("grpc-message")
    print(f"HTTP={sl}")
    print(f"content-type={hdrs.get('content-type')}")
    print(f"grpc-status={gs}  grpc-message={gm}")
    print(f"num_frames={len(frames)} flags={[hex(f) for f in frames]}")
