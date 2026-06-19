#!/usr/bin/env python3
"""Drive the Cognito Hosted-UI authorization-code + PKCE flow programmatically and
write the resulting id_token to a file.

The SPA client allows ONLY the OAuth `code` (PKCE) grant — admin-initiate-auth is
disabled (ExplicitAuthFlows: null). So there is no API shortcut to a token; we have
to act like the browser: GET /oauth2/authorize -> scrape the Hosted-UI /login form
(cookie jar + the `_csrf` hidden field) -> POST credentials -> capture the
`?code=` on the redirect back to the SPA callback -> exchange the code at
/oauth2/token with the PKCE code_verifier.

The id_token (not access_token) is what the Gateway validates: it carries
custom:tenant_id, which the pre-token-generation Lambda injects.

Env:
    COGNITO_DOMAIN   e.g. https://aegis-core-251774439261.auth.eu-central-1.amazoncognito.com
    CLIENT_ID        SPA app client id
    REDIRECT_URI     default http://localhost:5173/auth/callback
    SCOPE            default "openid email"

Usage:
    python3 cognito_pkce.py <username> <password> <out_id_token_path>

Exit non-zero (with a tagged reason) if the flow blocks anywhere, so the caller can
report exactly where it stopped instead of faking a pass.
"""
import sys, os, base64, hashlib, re, json, html, urllib.parse
import http.cookiejar, urllib.request, urllib.error

DOMAIN = os.environ["COGNITO_DOMAIN"].rstrip("/")
CLIENT_ID = os.environ["CLIENT_ID"]
REDIRECT = os.environ.get("REDIRECT_URI", "http://localhost:5173/auth/callback")
SCOPE = os.environ.get("SCOPE", "openid email")
USERNAME, PASSWORD, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ws4-verify"

verifier = base64.urlsafe_b64encode(os.urandom(40)).decode().rstrip("=")
challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
cj = http.cookiejar.CookieJar()
callback_path = urllib.parse.urlparse(REDIRECT).path


class StopRedirect(Exception):
    def __init__(self, url):
        self.url = url


class CatchCallback(urllib.request.HTTPRedirectHandler):
    """Follow redirects within the Cognito domain, but stop and surface the final
    redirect to the SPA callback (which has no live listener) so we can read the
    `?code=` off its URL. The callback host appears in redirect_uri query params on
    earlier hops too, so we match on the NEW url's path == callback_path, not a
    naive substring."""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        p = urllib.parse.urlparse(newurl)
        if p.scheme in ("http", "https") and p.path == callback_path and "code=" in (p.query or ""):
            raise StopRedirect(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


opener = urllib.request.build_opener(CatchCallback, urllib.request.HTTPCookieProcessor(cj))


def get(url):
    return opener.open(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=30)


def post(url, data, referer=None):
    h = {"User-Agent": UA, "Content-Type": "application/x-www-form-urlencoded"}
    if referer:
        h["Referer"] = referer
    return opener.open(urllib.request.Request(url, data=urllib.parse.urlencode(data).encode(), headers=h), timeout=30)


auth_url = (f"{DOMAIN}/oauth2/authorize?response_type=code&client_id={CLIENT_ID}"
            f"&redirect_uri={urllib.parse.quote(REDIRECT)}&scope={urllib.parse.quote(SCOPE)}"
            f"&code_challenge={challenge}&code_challenge_method=S256&state=ws4verify")

# Step 1: authorize -> Hosted-UI /login
try:
    resp = get(auth_url)
    login_html = resp.read().decode(errors="replace")
    login_url = resp.geturl()
except StopRedirect as e:
    print("BLOCKED:UNEXPECTED_EARLY_REDIRECT:" + e.url)
    sys.exit(2)

form_action = re.search(r'<form[^>]+action="([^"]+)"', login_html, re.I)
csrf = re.search(r'name="_csrf"[^>]*value="([^"]*)"', login_html, re.I)
if not form_action:
    print("BLOCKED:NO_LOGIN_FORM\n" + login_html[:1200])
    sys.exit(3)
action = html.unescape(form_action.group(1))
if action.startswith("/"):
    action = DOMAIN + action

hidden = dict(re.findall(r'<input[^>]+type="hidden"[^>]+name="([^"]+)"[^>]+value="([^"]*)"', login_html, re.I))
hidden.update(dict(re.findall(r'<input[^>]+name="([^"]+)"[^>]+type="hidden"[^>]+value="([^"]*)"', login_html, re.I)))
form = {k: html.unescape(v) for k, v in hidden.items()}
form["username"] = USERNAME
form["password"] = PASSWORD
if csrf:
    form["_csrf"] = html.unescape(csrf.group(1))

# Step 2: submit credentials -> capture ?code=
code = None
try:
    resp = post(action, form, referer=login_url)
    body = resp.read().decode(errors="replace")
    m = re.search(r'(?:error|alert)[^>]*>\s*([^<]+)<', body, re.I)
    print(f"BLOCKED:LOGIN_NO_REDIRECT final_url={resp.geturl()} msg={m.group(1).strip()[:160] if m else ''}")
    sys.exit(4)
except StopRedirect as e:
    code = urllib.parse.parse_qs(urllib.parse.urlparse(e.url).query).get("code", [None])[0]
except urllib.error.HTTPError as he:
    print(f"BLOCKED:LOGIN_HTTP_{he.code} {he.read().decode(errors='replace')[:400]}")
    sys.exit(4)

if not code:
    print("BLOCKED:NO_CODE")
    sys.exit(5)

# Step 3: exchange code for tokens
tok_data = {"grant_type": "authorization_code", "client_id": CLIENT_ID, "code": code,
            "redirect_uri": REDIRECT, "code_verifier": verifier}
try:
    req = urllib.request.Request(f"{DOMAIN}/oauth2/token",
                                 data=urllib.parse.urlencode(tok_data).encode(),
                                 headers={"User-Agent": UA, "Content-Type": "application/x-www-form-urlencoded"})
    tokens = json.loads(urllib.request.urlopen(req, timeout=30).read())
except urllib.error.HTTPError as he:
    print(f"BLOCKED:TOKEN_HTTP_{he.code} {he.read().decode(errors='replace')[:400]}")
    sys.exit(6)

id_token = tokens.get("id_token")
if not id_token:
    print("BLOCKED:NO_ID_TOKEN", tokens)
    sys.exit(7)


def claims_of(t):
    seg = t.split(".")[1]
    seg += "=" * (-len(seg) % 4)
    return json.loads(base64.urlsafe_b64decode(seg))


c = claims_of(id_token)
print("ID_TOKEN_OK")
print("CLAIMS:", json.dumps({k: c.get(k) for k in ["aud", "iss", "custom:tenant_id", "token_use", "email"]}))
with open(OUT, "w") as f:
    f.write(id_token)
