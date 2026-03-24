#!/usr/bin/env python3
"""
OAuth2 reverse proxy with JSON policy authorization.

Required env vars:
  OAUTH2_CLIENT_ID, OAUTH2_CLIENT_SECRET
  OAUTH2_AUTH_URL       e.g. https://github.com/login/oauth/authorize
  OAUTH2_TOKEN_URL      e.g. https://github.com/login/oauth/access_token
  OAUTH2_REDIRECT_URI   e.g. http://54.185.189.181:4181/auth/callback
  OAUTH2_UPSTREAM       e.g. https://api.github.com
  SIGN_IN_BASE_URL      e.g. http://54.185.189.181:4181
  AUTHZ_POLICY_FILE     e.g. /etc/oauth-proxy/policy.json

Optional:
  OAUTH2_SCOPE          default: "read:user user:email"
  OAUTH2_USERINFO_URL   default: https://api.github.com/user
  PORT                  default: 4180
"""
import json
import os
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

CLIENT_ID      = os.environ["OAUTH2_CLIENT_ID"]
CLIENT_SECRET  = os.environ["OAUTH2_CLIENT_SECRET"]
AUTH_URL       = os.environ["OAUTH2_AUTH_URL"]
TOKEN_URL      = os.environ["OAUTH2_TOKEN_URL"]
REDIRECT_URI   = os.environ["OAUTH2_REDIRECT_URI"]
UPSTREAM       = os.environ["OAUTH2_UPSTREAM"].rstrip("/")
SIGN_IN_BASE   = os.environ["SIGN_IN_BASE_URL"].rstrip("/")
POLICY_FILE    = os.environ["AUTHZ_POLICY_FILE"]
SCOPE          = os.environ.get("OAUTH2_SCOPE", "read:user user:email")
USERINFO_URL   = os.environ.get("OAUTH2_USERINFO_URL", "https://api.github.com/user")
PORT           = int(os.environ.get("PORT", 4180))


# ---------------------------------------------------------------------------
# Policy
# ---------------------------------------------------------------------------

def _is_allowed(userinfo: dict) -> bool:
    with open(POLICY_FILE) as f:
        policy = json.load(f)
    login = userinfo.get("login", "")
    email = userinfo.get("email") or ""
    if login in policy.get("allowed_logins", []):
        return True
    for domain in policy.get("allowed_email_domains", []):
        if email.endswith("@" + domain):
            return True
    return False


# ---------------------------------------------------------------------------
# Token state
# ---------------------------------------------------------------------------

_pending_state: str | None = None
_token: dict = {
    "access_token":  None,
    "refresh_token": None,
    "expires_at":    None,
}


# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def _fetch(url, *, method="GET", data=None, headers=None):
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.read(), r.headers
    except urllib.error.HTTPError as e:
        return e.code, e.read(), e.headers


# ---------------------------------------------------------------------------
# Token lifecycle
# ---------------------------------------------------------------------------

def _store(data: dict):
    _token["access_token"]  = data["access_token"]
    _token["refresh_token"] = data.get("refresh_token") or _token["refresh_token"]
    ei = data.get("expires_in")
    _token["expires_at"] = time.time() + int(ei) if ei else None


def _expired() -> bool:
    exp = _token["expires_at"]
    return exp is not None and time.time() >= exp - 30


def _try_refresh() -> bool:
    rt = _token["refresh_token"]
    if not rt:
        return False
    body = urllib.parse.urlencode({
        "grant_type":    "refresh_token",
        "refresh_token": rt,
        "client_id":     CLIENT_ID,
        "client_secret": CLIENT_SECRET,
    }).encode()
    status, resp, _ = _fetch(
        TOKEN_URL, method="POST", data=body,
        headers={"Accept": "application/json",
                 "Content-Type": "application/x-www-form-urlencoded"},
    )
    if status != 200:
        return False
    _store(json.loads(resp))
    return True


def _valid_token() -> str | None:
    if not _token["access_token"]:
        return None
    if _expired() and not _try_refresh():
        return None
    return _token["access_token"]


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):

    def do_GET(self):    self._dispatch("GET")
    def do_POST(self):   self._dispatch("POST")
    def do_PATCH(self):  self._dispatch("PATCH")
    def do_PUT(self):    self._dispatch("PUT")
    def do_DELETE(self): self._dispatch("DELETE")

    def _dispatch(self, method: str):
        global _pending_state
        parsed = urllib.parse.urlparse(self.path)

        if parsed.path == "/auth":
            _pending_state = secrets.token_urlsafe(16)
            qs = urllib.parse.urlencode({
                "client_id":     CLIENT_ID,
                "redirect_uri":  REDIRECT_URI,
                "scope":         SCOPE,
                "state":         _pending_state,
                "response_type": "code",
            })
            self._redirect(f"{AUTH_URL}?{qs}")

        elif parsed.path == "/auth/callback":
            qs    = urllib.parse.parse_qs(parsed.query)
            code  = qs.get("code",  [None])[0]
            state = qs.get("state", [None])[0]

            if _pending_state is None:
                return self._text(400, "No pending auth flow.")
            if not secrets.compare_digest(state or "", _pending_state):
                return self._text(400, "Invalid state — please try again.")

            body = urllib.parse.urlencode({
                "grant_type":    "authorization_code",
                "code":          code,
                "redirect_uri":  REDIRECT_URI,
                "client_id":     CLIENT_ID,
                "client_secret": CLIENT_SECRET,
            }).encode()
            status, resp, _ = _fetch(
                TOKEN_URL, method="POST", data=body,
                headers={"Accept": "application/json",
                         "Content-Type": "application/x-www-form-urlencoded"},
            )
            if status != 200:
                return self._text(500, "Token exchange failed.")

            token_data = json.loads(resp)
            if "access_token" not in token_data:
                return self._text(500, "No access_token in response.")

            s, b, _ = _fetch(USERINFO_URL, headers={
                "Authorization": f"Bearer {token_data['access_token']}",
                "User-Agent":    "oauth-proxy/1.0",
                "Accept":        "application/json",
            })
            if s != 200:
                return self._text(500, "Could not fetch userinfo.")

            userinfo = json.loads(b)

            if not _is_allowed(userinfo):
                return self._text(403, f"Access denied for {userinfo.get('login', 'unknown')}.")

            _store(token_data)
            _pending_state = None
            self._html(200, "<h2>Authenticated</h2><p>You may close this tab.</p>")

        elif parsed.path == "/status":
            self._json(200, {
                "authenticated": _token["access_token"] is not None,
                "expired":       _expired(),
                "has_refresh":   _token["refresh_token"] is not None,
                "expires_at":    _token["expires_at"],
            })

        else:
            self._proxy(method)

    def _proxy(self, method: str):
        tok = _valid_token()
        if not tok:
            return self._json(401, {
                "error":       "authentication_required",
                "sign_in_url": f"{SIGN_IN_BASE}/auth",
            })

        req_body = self._read_body()
        target   = UPSTREAM + self.path
        hdrs = {
            "Authorization": f"Bearer {tok}",
            "User-Agent":    "oauth-proxy/1.0",
        }
        for h in ("Accept", "Content-Type"):
            v = self.headers.get(h)
            if v:
                hdrs[h] = v

        status, body, resp_hdrs = _fetch(target, method=method, data=req_body, headers=hdrs)

        self.send_response(status)
        for h in ("Content-Type", "Link",
                  "X-RateLimit-Limit", "X-RateLimit-Remaining", "X-RateLimit-Reset"):
            v = resp_hdrs.get(h)
            if v:
                self.send_header(h, v)
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        n = self.headers.get("Content-Length")
        if n is None:
            return None
        return self.rfile.read(int(n))

    def _redirect(self, url):
        self.send_response(302)
        self.send_header("Location", url)
        self.end_headers()

    def _text(self, code, msg):
        b = msg.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b)

    def _html(self, code, body):
        b = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(b)

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b)

    def log_message(self, fmt, *args):
        print(f"[{self.address_string()}] {fmt % args}", flush=True)


if __name__ == "__main__":
    print(f"oauth-proxy :{PORT} → {UPSTREAM}", flush=True)
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
