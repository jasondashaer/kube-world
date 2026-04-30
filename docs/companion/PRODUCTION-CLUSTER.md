# Production Cluster Architecture

When State 1 (vanilla Companion at YIBC + Saitama) gives way to State 2
(full kube-world stack in production), the question is where the cluster
lives. The path settles into a clear default thanks to two enablers:

1. **Stream Decks use the Network module.** Connection is to a TCP
   endpoint, not a process. The endpoint can move from systemd
   Companion → in-pod Companion in seconds; Stream Decks reconnect on
   their next outbound TCP attempt. No re-pairing.
2. **Tailscale ACL is default-deny.** Even when K3s is running on a
   production Pi, Tailscale network isolation guarantees nothing
   reaches it unless `tag:maintenance` is explicitly toggled on.
   Operating with K3s on the production Pi does not weaken security
   compared to vanilla.

These together mean **in-place K3s on the existing production Pi** is
the simplest, most direct path to State 2. No cloud cluster needed for
production to work.

For the strategic context see
[ENVIRONMENT-STRATEGY.md](ENVIRONMENT-STRATEGY.md). For the cutover
procedure see [guides/k3s-cutover.md](guides/k3s-cutover.md). For why
we're running vanilla today see
[guides/site-handoff.md](guides/site-handoff.md).

---

## Recommended path: in-place K3s on the production Pi

```
┌────────────────────────────────────────────────────────────────────┐
│  Production site (e.g. YIBC)                                      │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ pi-yibc (Pi 5 16GB, single-node K3s server + agent)          │ │
│  │                                                              │ │
│  │   - K3s server (1-node cluster — no Karmada needed at first) │ │
│  │   - Companion (in-pod, hostNetwork: true)                    │ │
│  │     ↓ TCP/5343 outbound to Stream Decks (LAN)                │ │
│  │   - companion-deploy (init container — auto-import on        │ │
│  │     ConfigMap hash change)                                   │ │
│  │   - Sealed Secrets controller (per-cluster keypair)          │ │
│  │   - Local Flux GitRepository → tag-gated `prod-v*`           │ │
│  │                                                              │ │
│  │   Tailscale tags: companion + env-prod + site-yibc           │ │
│  │                   + k8s-control + k8s-worker                 │ │
│  │   Default-deny inbound except local LAN                      │ │
│  └──────────────────────────────────────────────────────────────┘ │
│       ↑                                                            │
│       │  Stream Decks (LAN, network module on TCP/5343)            │
│       │  AV systems (mixer, OBS, ProPresenter — LAN only)          │
└────────────────────────────────────────────────────────────────────┘
                                ↑
                                │  Tailscale (admin only, during
                                │  maintenance windows; default-deny
                                │  otherwise)
                                ↓
                         Your Mac / laptop
```

### Properties

- **Latency to Stream Decks**: same as vanilla (local LAN).
- **Operator self-service when broken**: same as vanilla (power-cycle
  the Pi). K3s adds K3s-specific failure modes but those are visible
  via `kubectl` only during a maintenance window.
- **Cost**: hardware only (the Pi you already own).
- **Sovereignty**: full local. No cloud dependency for runtime.
- **Reachability for you**: only during a maintenance window via
  Tailscale. ACL prevents drive-by access.

### Cutover

[guides/k3s-cutover.md](guides/k3s-cutover.md) walks the procedure.
~3-5 minutes downtime. Stream Decks reconnect automatically because
they're on the LAN to the same Pi IP.

### Limitations

- **Single point of failure per site.** If the Pi dies hardware-wise,
  that site is dark. Mitigation: ship a spare Pi to each site
  pre-imaged with the same vanilla install. Cutover the spare to K3s
  on demand.
- **No multi-site scheduling primitives.** Each site's cluster is
  independent. If you want cross-site Karmada workload migration,
  you need a separate control plane (see Phase C below).
- **Per-site Sealed Secrets keypair.** Each cluster has its own keypair,
  so a SealedSecret from YIBC cluster does NOT decrypt at Saitama.
  This is the intended security boundary.

---

## Phase plan

### Phase A: Today — Vanilla
Both YIBC and Saitama run vanilla Companion. Pi has Tailscale with base
tags (no `tag:maintenance`). Operators run their services. You support
remotely via [maintenance-access.md](guides/maintenance-access.md).

### Phase B: First site cuts over to K3s in-place
Pick one site to migrate first (recommend YIBC — closer to your dev
home setup). Open maintenance window, run cutover script, verify, close
window. Now YIBC has full kube-world stack with auto-import GitOps.

Saitama stays vanilla until you're confident in YIBC's K3s operation.

### Phase C: Second site cuts over
Saitama gets the same treatment. Both production sites now on full
stack. Each is its own independent cluster.

### Phase D (optional, only when needed): separate control plane
You add a third site, OR you want centralized monitoring across sites,
OR you want cross-site Karmada workload scheduling. Then bring up a
**separate Karmada control plane** somewhere:

- **Phase D1 (preferred when you live in Japan)**: a fourth Pi at your
  home in Japan as the Karmada control plane. Existing church Pis
  re-register as Karmada members. No site-side cutover.
- **Phase D2 (alternative, for ergonomics if you're abroad)**: a cheap
  cloud VM (Hetzner CX22 ~€4.51/mo) as the Karmada control plane. Same
  re-registration; no site-side cutover.

Phase D is **not required** to get production benefits. A 2-site
deployment without a separate control plane works fine — each site is
a Karmada-less single-cluster K3s with its own Flux pulling from the
shared GitLab repo.

---

## Cloud control plane (Phase D2) — when it makes sense

Demoted from the previous draft. The case for it is narrower than I
thought before:

| Triggers a cloud control plane | Notes |
|---|---|
| Three or more production sites | Per-site Flux + Sealed Secrets duplication starts to hurt |
| You want one Rancher to monitor all sites | Convenience, not necessity |
| You want cross-site workload migration (e.g. failover mixer-state-deploy) | Mostly hypothetical; never needed yet |
| You want a stable identity provider (Zitadel) reachable from sites' OIDC clients | Only if you're using OIDC for AV systems |

For a 2-site deployment, none of these are urgent. Stay flat.

---

## Failure modes per phase

| Phase | What can break | Recovery |
|---|---|---|
| A vanilla | Pi hardware, Companion crash, OS issue | Hot-swap spare Pi pre-imaged; restore from `/etc/default/companion` backup + Companion DB export |
| B/C k3s in-place | Pi hardware, K3s control plane crash, etcd corruption, Pod scheduling | `cutover.sh --rollback` reverts to vanilla in ~2min if you can't fix K3s. Hot-swap Pi same as vanilla. |
| D centralized | All of the above + control plane network partition | Edge clusters keep running last-known config (etcd is local on each Pi); reconnect when control plane returns. |

---

## Decommission paths

| Want | Path |
|---|---|
| Take a site offline temporarily | `kubectl scale deployment/companion -n companion --replicas=0` (k3s mode) or `systemctl stop companion` (vanilla) |
| Move a site to a different facility | Image the Pi, ship to new location, update LAN IP if changed (DHCP reservation handles this), Stream Decks re-discover the Pi |
| Replace the Pi entirely | Vanilla path: re-run install.sh on new Pi + restore env file + re-import seed. K3s path: provision new Pi with cutover.sh, migrate PVC data |
| Fully retire the project | Stop the cluster, archive the repo, hand the operators a final exported Companion config blob they can import on any future Companion install |

---

## Cross-references

- Environment + dev/prod strategy: [ENVIRONMENT-STRATEGY.md](ENVIRONMENT-STRATEGY.md)
- Vanilla install (state today): [guides/site-handoff.md](guides/site-handoff.md)
- K3s cutover procedure: [guides/k3s-cutover.md](guides/k3s-cutover.md)
- Tailscale default-deny ACL: [`infrastructure/tailscale-acl.json`](../../infrastructure/tailscale-acl.json)
- Maintenance access: [guides/maintenance-access.md](guides/maintenance-access.md)
- Karmada propagation policies (multi-cluster mode): `karmada/propagation-policies/companion.yaml`
- Bootstrap script: `bootstrap.sh`
