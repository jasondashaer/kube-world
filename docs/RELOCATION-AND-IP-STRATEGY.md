# Relocation & IP-Stability Strategy

Context: pi-central + pi-edge-1 relocate Japan → US (still in service for
other projects). YIBC + Saitama Companion Pis stay in Japan at the
churches. No DHCP reservations available on the church routers.

The governing rule: **Tailscale IPs (`100.x`) are the only
location-independent addresses.** LAN IPs change on every network move
and on DHCP churn. Anything that must survive a move or a lease change
references the Tailscale IP / MagicDNS name, never a LAN IP.

## What survives the move (already correct)

| Path | Why it's safe |
|---|---|
| `karmada-kubeconfig` secret | server = `https://100.127.190.120:32443` (pi-central Tailscale IP) |
| Flux `GitRepository` | URL = `http://gitlab.gitlab.svc.cluster.local` (in-cluster DNS) |
| `pi-edge-1-kubeconfig` secret | **fixed 2026-05-18** → `https://100.111.33.94:6443` (pi-edge-1 Tailscale IP) + k3s `tls-san` now includes that IP/DNS |
| `deploy-yibc.sh` / `deploy-saitama.sh` | target `*.tailab53c1.ts.net:8000` over Tailscale — work from anywhere incl. US |
| YIBC + Saitama Companion | standalone CompanionPi, off Flux/Karmada (Phase 8). No dependency on central/edge1 location |

## pi-edge-1 k3s tls-san (move-critical)

`/etc/rancher/k3s/config.yaml` on pi-edge-1:

```yaml
tls-san:
  - "100.111.33.94"               # Tailscale IP — primary, move-safe
  - "pi-edge-1.tailab53c1.ts.net" # MagicDNS
  - "pi-edge-1"
  - "192.168.0.145"               # LAN fallback (Japan)
```

If pi-edge-1's Tailscale IP ever changes (rare — only on logout/key
reset), regenerate the serving cert: delete
`/var/lib/rancher/k3s/server/tls/serving-kube-apiserver.{crt,key}`,
update `tls-san`, `systemctl restart k3s`, then repoint the
`pi-edge-1-kubeconfig` secret + reconcile `infra-edge1-raw`.

Same pattern applies to pi-central if its Karmada endpoint ever moves
off the current Tailscale IP.

## Church-site LAN IP stability (no DHCP reservations)

Companion *dials out* to local AV gear, so those device IPs must be
stable even though the church routers can't reserve them. The Pi's own
LAN IP does NOT matter (deploy uses Tailscale; Companion initiates the
AV connections).

Priority order:

1. **Stream Deck Network Docks → static IP on the dock itself.**
   Dock Setup screen → `Mode: DHCP` → switch to Static, assign a fixed
   address outside the router's DHCP pool. Kills the worst churn
   (e.g. MK2 drifted .13→.36→… repeatedly). Update the matching
   `address:` in `apps/companion/config/sites/<site>/surfaces.yaml`,
   then `deploy-<site>.sh`.
2. **AV gear static at the device:**
   - PTZ camera: web UI → Network → static
   - ProP / OBS Macs: macOS → Network → Manually. ProP also advertises
     Bonjour, so `<machine-name>.local` works as a no-config fallback
     in the connection config.
   - Yamaha TF mixers: console Network settings → static
3. **Pis stay DHCP** — nothing depends on their church-LAN IP.
   Reachable + deployable via Tailscale regardless.

## Quick reference — who reaches whom

- Workstation (US) → church Companion: Tailscale FQDN, `deploy-*.sh`
- pi-central Flux → pi-edge-1 API: Tailscale IP `100.111.33.94:6443`
- pi-central Flux → Karmada: Tailscale IP `100.127.190.120:32443`
- Companion (church Pi) → local AV gear: church LAN, static device IPs
- Stream Deck docks ← Companion dials out: church LAN, static dock IPs

## On arrival in the US (pi-central + pi-edge-1)

Nothing to reconfigure for Flux/Karmada — all cross-node paths are
Tailscale-pinned. Sanity-check after the move:

```sh
ssh admin@pi-central.tailab53c1.ts.net \
  'kubectl -n flux-system get kustomizations | grep -v True'   # expect empty
```

Church AV is unaffected by the move; verify independently:

```sh
./apps/companion/scripts/deploy-yibc.sh --generate-only        # bundle builds
ssh admin@yibc.tailab53c1.ts.net 'systemctl is-active companion'
ssh admin@msn-saitama.tailab53c1.ts.net 'systemctl is-active companion'
```
