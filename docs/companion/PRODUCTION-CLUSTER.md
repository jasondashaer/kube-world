# Production Cluster Architecture

When State 1 (vanilla Companion at YIBC + Saitama) gives way to State 2
(full kube-world stack in production), the production cluster needs to
exist somewhere. This doc evaluates the options and lays out the path.

For the staged approach explaining when this transition happens, see
[ENVIRONMENT-STRATEGY.md](ENVIRONMENT-STRATEGY.md). For why we're
running vanilla today, see [guides/site-handoff.md](guides/site-handoff.md).

---

## Decision matrix

| Option | Latency to Stream Decks | Operator-self-service when broken? | Cost / month | Sovereignty |
|---|---|---|---|---|
| **A. On-Pi K3s, in the church** | local LAN, < 1ms | Operator can power-cycle Pi; you fix anything else | hardware-only | full local |
| **B. Cloud K3s (Hetzner / DO / GCP)** | ~50-200ms to Tokyo | Cloud is up; Stream Decks reach via tunnel | $5-20 + bandwidth | cloud-dependent |
| **C. Hybrid — cloud control plane + on-Pi data plane** | local for Companion, cloud for orchestration | Pi keeps Companion running standalone if cloud is down | $5-15 | mixed |
| **D. Fully on-prem with you-in-Japan as ops** | local | You ARE the operator | hardware-only | full local |

The decision changes based on **where you live**:

- **You in US / not Japan**: **Option C** is best. Cloud control plane
  = always reachable for you to push changes; on-Pi data plane keeps
  the church running regardless of cloud connectivity. Edge clusters
  in Karmada is exactly this pattern.
- **You in Japan, near the churches**: **Option D** is best. Skip
  the cloud roundtrip. Treat the production Pi cluster like dev —
  local, on-prem, you operate it.
- **You traveling between**: **Option C** (until you settle).

The default plan: **start with C, simplify to D once you're permanent
in Japan.** The C → D transition is mostly removing the cloud control
plane Pod — the on-Pi cluster is the same.

---

## Option C in detail (recommended near-term)

### Topology

```
┌────────────────────────────────────────────────────────────────────┐
│  Cloud (Hetzner CX22 = €4.51/mo, 2 vCPU + 4GB RAM)                 │
│                                                                    │
│  ┌────────────────────────────────────────────────────────────┐   │
│  │ pi-central-cloud (K3s server, control plane only)          │   │
│  │   - Karmada control plane                                  │   │
│  │   - Flux + GitLab/GitHub mirror                            │   │
│  │   - Rancher (UI for you to monitor from anywhere)          │   │
│  │   - Sealed Secrets controller (for prod cluster keypair)   │   │
│  │   - cert-manager + Traefik (only for the cloud's services) │   │
│  └────────────────────────────────────────────────────────────┘   │
│       ↑ Tailscale + Karmada agent register from edge clusters     │
└────────────────────────────────────────────────────────────────────┘
                                ↑
                                │ Tailscale (tail-scaled k8s API auth)
                                ↓
┌────────────────────────────────────────────────────────────────────┐
│  Production sites (each Pi an independent K3s cluster)             │
│                                                                    │
│  ┌──────────────────────┐  ┌──────────────────────┐                │
│  │ pi-yibc (Pi 5 16GB)  │  │ pi-saitama (Pi 5)    │                │
│  │   K3s server (1-node)│  │   K3s server         │                │
│  │   Companion + auto-  │  │   Companion + auto-  │                │
│  │   import init cont.  │  │   import init cont.  │                │
│  │   Sealed Secrets ctrl│  │   Sealed Secrets ctrl│                │
│  │   Karmada agent      │  │   Karmada agent      │                │
│  └──────────────────────┘  └──────────────────────┘                │
│       ↑                          ↑                                 │
│       │  Stream Decks (LAN)      │  Stream Decks (LAN)             │
└────────────────────────────────────────────────────────────────────┘
```

### Why this works

- **Stream Decks talk to Companion locally.** Sub-millisecond response.
  Cloud disconnect doesn't affect a live service.
- **You push changes from anywhere.** Git push → cloud Flux reconciles
  → Karmada propagates to edge clusters. Edge clusters cache the spec
  in their local etcd; if they lose cloud connectivity mid-reconcile,
  they keep running the last-known-good config.
- **Edge clusters are autonomous for runtime.** The Karmada agent
  syncs back to cloud when reachable, but the local K3s + Companion
  Pod operates independently.
- **Cloud is the always-reachable bastion** for kubectl / monitoring.
  When something breaks, you can reach Rancher from any device with
  Tailscale, see logs, push fixes.

### What's different from current dev setup

You're already running this pattern at home, just with pi-central
playing the cloud's role. The cutover:

1. Provision a cheap cloud VM (Hetzner CX22 or similar — €4.51/mo).
2. Bootstrap K3s + Karmada + Flux + Rancher + Zitadel on it (existing
   `bootstrap.sh` works — just point at the cloud node).
3. Migrate the Karmada API endpoint from pi-central LAN to the cloud
   public IP (over Tailscale).
4. Edge Pis (pi-yibc, pi-saitama) join the cloud Karmada via
   Tailscale — same `karmadactl join` command you already use, just
   different control plane.
5. Decommission pi-central. Or keep it as a backup control plane.

The repo's manifests don't change.

### Failure modes

| Failure | Effect | Mitigation |
|---|---|---|
| Cloud down | Edge clusters keep running last-known config; you can't push new changes for the duration | Cloud provider chosen for high availability; cheap VMs from established providers (Hetzner, DO) hit ~99.9% |
| Edge cluster (Pi) down | That site is dark; other site still works; you can push changes to the surviving site | Mixer + Pi power redundancy; ship spare Pi to each site for hot replacement |
| Tailscale down | Cloud and edge can't sync; same as cloud down for that edge | Tailscale failures rare; LAN-direct fallback possible if you cache control plane addresses |
| Pushed broken YAML | Flux reconciles → broken state → Companion stops responding | Validate stage in CI catches most; live test runbook catches the rest; rollback by re-tagging |
| Cloud provider account suspended | All edge clusters lose control plane | Bootstrap script + git is portable to any new cloud provider in <1hr |

### Costs

| Item | Monthly |
|---|---|
| Hetzner CX22 (cloud control plane) | ~€4.51 |
| Tailscale | $0 (free tier ≤3 users, ≤100 devices) |
| Cloudflare DNS | $0 |
| Cloudflare Tunnel (if used instead of public IP) | $0 |
| Backups (Hetzner snapshots) | ~€1 |
| Total | **< €6** |

---

## Option D — fully on-prem (your-in-Japan future state)

When you live near the churches, the cloud bastion isn't load-bearing.
Simplification:

- Drop the cloud control plane.
- Keep the existing pi-central in your home in Japan as control plane,
  OR run Karmada control plane co-located on one of the church Pis
  (single-cluster mode, no Karmada).
- Tailscale still useful for your laptop → cluster API access from
  outside the home LAN.

The repo manifests don't change. The transition is removing the cloud
node from the inventory.

---

## Path to get there

### Phase A: Today
Vanilla Companion at YIBC + Saitama (operator-owned). You build kube-
world stack at home for development. No production K3s anywhere yet.

### Phase B: Cloud prod cluster up (pre-move-to-Japan)
- Provision Hetzner CX22 (or equivalent).
- Run `bootstrap.sh --platform cloud --stack karmada` (or whatever
  the cloud-mode flag becomes — TODO add cloud platform support to
  bootstrap.sh).
- Bring up Sealed Secrets, Flux GitRepository tracking `prod-v*` tags.
- DOES NOT CUT OVER any production site yet — cloud cluster is empty
  except for the platform.

### Phase C: First production site cut over to k3s
- Pick one (probably YIBC since you're more familiar with it).
- Procedure: see [guides/site-handoff.md](guides/site-handoff.md)
  §"When to flip a site to k3s mode". Stop systemd Companion, install
  K3s on Pi, join cloud Karmada, apply manifests.
- Run for several services without touching anything to confirm
  stability.

### Phase D: Second site cut over
Same procedure for Saitama. Both production sites now on full kube-
world stack.

### Phase E: You move to Japan
Keep cloud cluster temporarily. Add a Pi cluster at your home in
Japan. When the home cluster is the primary control plane,
decommission cloud. Or keep cloud as a backup control plane.

---

## Open questions (will need decisions when Phase B starts)

- **Cloud provider choice**: Hetzner (cheapest, EU region) vs DigitalOcean
  (Tokyo region, slightly higher latency to your laptop in US, cheaper
  for the churches) vs GCP (in-Japan region, higher cost). Latency
  for *your push* doesn't matter much — what matters is provider
  reliability + region near the churches for control plane reachability
  during issues.
- **DNS**: Cloudflare with `kubew.dev` already in place. Add `prod.kubew.dev`
  for the cloud cluster control plane (Rancher / Karmada API).
- **Backups**: Velero already in repo manifests. Confirm Hetzner storage
  bucket vs S3-compatible alternative for backup target.
- **Disaster recovery**: time-to-recover from total cloud loss = bootstrap
  script + git repo. Should be <1hr if practiced quarterly.
- **Karmada or single-cluster?**: With 2 production sites, Karmada gives
  multi-cluster scheduling that's mostly overkill. Single cluster per
  site + Flux pulling from the same repo would be simpler. Tradeoff:
  loss of cross-cluster scheduling primitives that we're not actually
  using yet.

These are not blocking — they get answered when Phase B starts.

---

## Cross-references

- Environment strategy: [ENVIRONMENT-STRATEGY.md](ENVIRONMENT-STRATEGY.md)
- Vanilla mode (current state): [guides/site-handoff.md](guides/site-handoff.md)
- Karmada propagation: `karmada/propagation-policies/companion.yaml`
- Bootstrap: `bootstrap.sh`
