#!/usr/bin/env python3
"""Zitadel Actions v2 webhook: Entra group membership -> HA role (user metadata).

Hooks the response of /zitadel.user.v2.UserService/RetrieveIdentityProviderIntent
(fires under the Login V2 IdP-intent flow, where legacy Actions v1 external-auth
triggers do NOT). Reads the Entra group GUIDs out of the federated id_token JWT,
maps them to HA roles, and writes them to the Zitadel user's `ha_roles` metadata.
The flow-2 `flattenRoles` action then merges that metadata into the flat `groups`
claim that hass-oidc-auth reads.

Stdlib only (runs on stock python:3.x-slim, multi-arch). No external deps.

Env:
  GROUP_ROLE_MAP    JSON object {entraGroupGuid: haRole}. Required.
  ZITADEL_API       Base URL of in-cluster Zitadel (e.g. http://zitadel.zitadel.svc.cluster.local:8080).
  ZITADEL_HOST      Host header Zitadel routes by (e.g. auth.kubew.dev).
  ZITADEL_API_TOKEN Bearer PAT with rights to write user metadata.
  TARGET_SIGNING_KEY  HMAC key from the Actions v2 Target (for signature verify).
  REQUIRE_SIGNATURE  "true" to reject unsigned/bad-signature calls; default "false" (log only).
  METADATA_KEY       Metadata key to write; default "ha_roles".
  LISTEN_PORT        default 8080.
"""
import base64
import hashlib
import hmac
import json
import os
import sys
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, HTTPServer

GROUP_ROLE_MAP = json.loads(os.environ.get("GROUP_ROLE_MAP", "{}"))
ZITADEL_API = os.environ.get("ZITADEL_API", "http://zitadel.zitadel.svc.cluster.local:8080").rstrip("/")
ZITADEL_HOST = os.environ.get("ZITADEL_HOST", "")
ZITADEL_API_TOKEN = os.environ.get("ZITADEL_API_TOKEN", "")
TARGET_SIGNING_KEY = os.environ.get("TARGET_SIGNING_KEY", "")
REQUIRE_SIGNATURE = os.environ.get("REQUIRE_SIGNATURE", "false").lower() == "true"
METADATA_KEY = os.environ.get("METADATA_KEY", "ha_roles")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8080"))


def log(*a):
    print("[groupsync]", *a, flush=True)


def b64url_decode(seg):
    seg += "=" * (-len(seg) % 4)
    return base64.urlsafe_b64decode(seg)


def verify_signature(raw_body, header):
    """Zitadel signs Stripe-style: 'Zitadel-Signature: t=<unix>,v1=<hex hmac>'.
    HMAC-SHA256 over '<t>.<raw_body>' with the Target signing key."""
    if not header or not TARGET_SIGNING_KEY:
        return False
    parts = dict(p.split("=", 1) for p in header.split(",") if "=" in p)
    t, v1 = parts.get("t"), parts.get("v1")
    if not t or not v1:
        return False
    mac = hmac.new(TARGET_SIGNING_KEY.encode(), (t + "." + raw_body).encode(), hashlib.sha256)
    expected = mac.hexdigest()
    ok = hmac.compare_digest(expected, v1)
    if not ok:
        log("signature mismatch: received v1=%s computed=%s" % (v1, expected))
    return ok


def extract_groups(payload):
    """Entra group GUIDs live in the federated id_token JWT (claim 'groups')."""
    idp = (payload.get("response") or {}).get("idpInformation") or {}
    id_token = (idp.get("oauth") or {}).get("idToken")
    if not id_token:
        log("no idToken in idpInformation.oauth")
        return []
    try:
        claims = json.loads(b64url_decode(id_token.split(".")[1]))
    except Exception as e:
        log("idToken decode failed:", e)
        return []
    groups = claims.get("groups") or []
    return groups if isinstance(groups, list) else []


def zitadel_user_id(payload):
    return (payload.get("response") or {}).get("userId") or payload.get("userID")


def _api(method, path, body=None):
    url = ZITADEL_API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + ZITADEL_API_TOKEN)
    req.add_header("Content-Type", "application/json")
    if ZITADEL_HOST:
        req.add_header("Host", ZITADEL_HOST)
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:
        return 0, str(e)


def set_roles_metadata(user_id, roles):
    if roles:
        value = base64.b64encode(json.dumps(roles).encode()).decode()
        st, resp = _api("POST", "/management/v1/users/%s/metadata/%s" % (user_id, METADATA_KEY),
                        {"value": value})
        log("set %s=%s for %s -> %s %s" % (METADATA_KEY, roles, user_id, st, resp[:120]))
    else:
        # No mapped roles -> remove the key so de-assignment in Entra revokes the role.
        st, resp = _api("DELETE", "/management/v1/users/%s/metadata/%s" % (user_id, METADATA_KEY))
        log("cleared %s for %s -> %s %s" % (METADATA_KEY, user_id, st, resp[:120]))


def handle(payload):
    user_id = zitadel_user_id(payload)
    if not user_id:
        log("no zitadel userId in payload, skipping")
        return
    groups = extract_groups(payload)
    roles = []
    for g in groups:
        r = GROUP_ROLE_MAP.get(g)
        if r and r not in roles:
            roles.append(r)
    log("user=%s entra_groups=%s -> roles=%s" % (user_id, groups, roles))
    set_roles_metadata(user_id, roles)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n).decode("utf-8", "replace")
        sig_hdr = self.headers.get("Zitadel-Signature", "")
        sig_ok = verify_signature(raw, sig_hdr)
        log("sig: header_present=%s verified=%s" % (bool(sig_hdr), sig_ok))
        if REQUIRE_SIGNATURE and not sig_ok:
            log("rejecting: signature required but invalid")
            self.send_response(401)
            self.end_headers()
            return
        try:
            payload = json.loads(raw)
            handle(payload)
        except Exception as e:
            log("handler error (non-fatal):", e)
        # Always 200 — webhook must never block login (Target interruptOnError=false).
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")


def main():
    if not GROUP_ROLE_MAP:
        log("WARNING: GROUP_ROLE_MAP empty — no groups will map to roles")
    log("listening on :%d, zitadel=%s require_sig=%s" % (LISTEN_PORT, ZITADEL_API, REQUIRE_SIGNATURE))
    HTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
