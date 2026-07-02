# Cloudflare Tunnel — public Home Assistant access

Makes Home Assistant reachable at a **public** hostname (`ha.kubew.dev`) with no
inbound ports, no exposed cluster, and **no Tailscale required for clients**.
Intended so a non-technical user (e.g. a family member) can reach HA from
anywhere with just a URL + login.

The existing tailnet host `ha.edge1.kubew.dev` is **untouched** — it stays
Tailscale-only and remains the OIDC/SSO host. `ha.kubew.dev` is a separate public
door that uses HA's normal login (a **local HA account** is recommended for the
family user, since the mobile OIDC device-code flow is clunky — see
[../home-assistant/OIDC-LOGIN.md](../home-assistant/OIDC-LOGIN.md)).

## How it works

```
dad's phone/browser
  → https://ha.kubew.dev            (public DNS → Cloudflare edge, TLS terminated here)
    → Cloudflare Tunnel
      → cloudflared pod (edge1, home-assistant ns)   ── dials OUT :443, no inbound ports
        → http://home-assistant.home-assistant.svc.cluster.local:8123
```

**Remote-managed (token) tunnel:** the hostname→service route and the DNS record
are configured in the Cloudflare Zero Trust dashboard. The in-cluster connector
only needs the tunnel **token**. cloudflared reads it from `TUNNEL_TOKEN`
(sourced from the `cloudflared-token` Secret).

## GitOps pieces (in this repo)

- [deployment.yaml](deployment.yaml) — the `cloudflared` Deployment (edge1,
  `home-assistant` ns), pinned image `docker.io/cloudflare/cloudflared:2026.6.1`.
- [../../karmada/propagation-policies/cloudflared.yaml](../../karmada/propagation-policies/cloudflared.yaml)
  — propagates it to `workload-type=iot` (edge1).
- Flux Kustomization `apps-cloudflared` in
  [../../flux/kustomizations/apps.yaml](../../flux/kustomizations/apps.yaml).
- `docker.io/cloudflare/*` added to the Kyverno trusted-registry allowlist in
  [../../policies/kyverno-policies.yaml](../../policies/kyverno-policies.yaml).

## One-time setup (NOT reproducible from git — external + secret)

### 1. Create the tunnel in Cloudflare (dashboard)

1. Cloudflare → **Zero Trust** → **Networks** → **Tunnels** → **Create a tunnel**
   → type **Cloudflared** → name it (e.g. `kube-world-ha`) → **Save**.
2. On the connector page, **copy the token** (the long string in the
   `cloudflared ... run <TOKEN>` install command). This is the only value the
   cluster needs.
3. **Public Hostname** tab → **Add a public hostname**:
   - Subdomain `ha`, Domain `kubew.dev`  → `ha.kubew.dev`
   - Service **Type** `HTTP`, **URL**
     `home-assistant.home-assistant.svc.cluster.local:8123`
   - Save. Cloudflare auto-creates the proxied DNS record `ha.kubew.dev` (this
     more-specific record wins over the existing `*.kubew.dev` wildcard).

### 2. Create the token Secret on the edge cluster (never committed)

The tunnel token is a secret and is created imperatively on the cluster where the
pod runs (edge1), mirroring how `ha-oidc-config` is handled. Sealed-secrets is
not currently running, so do NOT commit the token.

```bash
kubectl --kubeconfig ~/.kube/pi-edge-1-config -n home-assistant \
  create secret generic cloudflared-token \
  --from-literal=token='PASTE_THE_TUNNEL_TOKEN_HERE'
```

Once the Secret exists and Flux has synced the manifests, the `cloudflared` pod
starts, registers with Cloudflare (tunnel shows **HEALTHY**), and `ha.kubew.dev`
serves Home Assistant.

## Reproducibility caveat

If the edge cluster is wiped, re-run step 2 (the token Secret) — it is not in
git. The tunnel + public hostname in the Cloudflare dashboard persist
independently. The Deployment, propagation, and policy allowlist ARE in git and
restore automatically.

## Verify

```bash
kubectl --kubeconfig ~/.kube/pi-edge-1-config -n home-assistant \
  get pods -l app.kubernetes.io/name=cloudflared
kubectl --kubeconfig ~/.kube/pi-edge-1-config -n home-assistant \
  logs deploy/cloudflared | grep -i "registered\|connection\|error"
```

Then open `https://ha.kubew.dev` — HA login should load with valid HTTPS.
