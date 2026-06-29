# Home Assistant OIDC login (Zitadel SSO via Entra)

HA authenticates through the `hass-oidc-auth` custom component (`auth_oidc`,
pinned v1.0.2). Config lives in [config.yaml](config.yaml) under the `auth_oidc:`
block. Identity chain: HA → Zitadel (`auth.kubew.dev`) → Microsoft Entra ID.

## Web / desktop browser — just works

Open `https://ha.edge1.kubew.dev`. The component intercepts `/auth/authorize`,
sets a state cookie, and auto-redirects through Zitadel → Entra → back to HA.
No provider button to pick; SSO is automatic.

## Mobile Companion app (Android / iOS) — use the DEVICE-CODE flow

### The limitation

`hass-oidc-auth` does **not** support direct in-app sign-in. From the upstream
FAQ: "Several attempts have been made at implementing a direct mobile sign-in,
but due to many issues … an approach was chosen that works for all setups."
The blocker is the app's embedded webview (Android WebView / iOS WKWebView).

**Therefore: the in-app "Sign in with Zitadel SSO" provider button does NOT
work and aborts with "Login aborted."** This is expected, not a misconfiguration.
Server-side the abort is `no_oidc_cookie_found` — the button starts a login flow
without first completing the welcome page that sets the `auth_oidc_state` cookie.

### The supported process (this is the one that works)

1. In the Companion app, if a server is already added, **sign out / remove it
   and re-add** `https://ha.edge1.kubew.dev`. (Clears stale webview state so the
   app loads a fresh `/auth/authorize`.)
2. The app now shows a short **device code** with text like *"login on another
   device and enter this code."* Do **not** tap any provider button.
3. On the **same phone**, open **Chrome (Android) / Safari (iOS)** (a real
   browser, not the app webview) and go to `https://ha.edge1.kubew.dev`.
4. Log in there: **Zitadel SSO → Microsoft Entra**.
5. When prompted, **enter the device code** from step 2.
6. The app detects completion automatically (server-sent events on
   `/auth/oidc/device-sse`) and finishes login. Keep the app open.

### Why no config change fixes this

- `features.default_redirect` only skips the welcome screen on **desktop**;
  `welcome.py` never auto-redirects when the client is mobile — it always shows
  the code. So this flag has no effect on mobile.
- `features.force_https` is unnecessary: HA sits behind Traefik TLS and trusts
  `X-Forwarded-Proto`, so the state cookie is already issued `Secure`.

The device-code flow is the intended and only supported mobile path.

## Quick server-side health check

Simulate the companion app's authorize request from any machine:

```bash
curl -sS -L -D - -o /dev/null \
  'https://ha.edge1.kubew.dev/auth/authorize?response_type=code&client_id=https%3A%2F%2Fhome-assistant.io%2FAndroid&redirect_uri=homeassistant%3A%2F%2Fauth-callback&state=test'
```

Healthy output: `302` → `/auth/oidc/welcome?...` → `200` with a
`set-cookie: auth_oidc_state=...; Secure` header. The 200 body is the
device-code page. If you see that, server-side OIDC is fine and any mobile
trouble is the in-app-button path described above.
