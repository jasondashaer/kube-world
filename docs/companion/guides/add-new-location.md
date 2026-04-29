# Guide: Add a New Location

Bring up a new church / venue location with its own systems (mixer, ProPresenter, OBS, PTZ, Stream Decks). This is a bigger lift than adding a single device — it touches connections, pages, surfaces, and docs.

## Prerequisites

- A K3s cluster running at the new location (or planned to be added — see [kube-world adding a new edge cluster](../../../README.md#adding-a-new-edge-cluster)).
- LAN with the AV systems reachable.
- Tailscale joining the new cluster's Pi to the tailnet.
- A short location name (lowercase, no spaces) — used as a suffix in connection IDs and a directory name. Example: `yibc`, `saitama`, `tokyo_2`.

This guide assumes the new location is named `<loc>` throughout.

---

## Step 1 — Network requirements

Confirm the new location's LAN:

| System | Default port | Verify |
|--------|--------------|--------|
| Yamaha TF mixer | RCP on TCP 49280 | `nc -zv <mixer-ip> 49280` |
| ProPresenter 7 | TCP, configurable (1025 / 53678 / etc.) | check PP Network preferences |
| PTZ Optics camera | VISCA on TCP 5678 (or UDP 1259) | `nc -zv <camera-ip> 5678` |
| OBS WebSocket | TCP 4455 | `nc -zv <obs-host> 4455` |
| ATEM | TCP 9910 (proprietary) | `nc -zv <atem-ip> 9910` |
| Blackmagic recorder (HyperDeck) | TCP 9993 | `nc -zv <recorder-ip> 9993` |

The Pi running Companion at the new location needs route to all of the above. If they're on different VLANs, get firewall rules added.

## Step 2 — Create page directory + initial pages

```bash
mkdir -p apps/companion/config/pages/<loc>
```

Choose page numbers from a free range (see [pages/README.md](../pages/README.md#numbering-convention)). Reserve a 10-page block for the location (e.g. 60-69 for a third location).

Copy a similar location's pages as a starting point:

```bash
cp apps/companion/config/pages/saitama/xl-page01-home.yaml \
   apps/companion/config/pages/<loc>/xl-page01-home.yaml
```

Edit:
- Update `page.number` to a free number in the location's range.
- Replace all `<connection_id>` references (e.g. `yamaha_saitama` → `yamaha_<loc>`).
- Adjust channel mappings, scene names, OBS scene names to match the new location's setup.

## Step 3 — Add location-specific connections

In `apps/companion/config/connections.yaml`, add entries for each system at the new location, using `_<loc>` suffix. See [add-new-system.md](add-new-system.md) for per-connection details.

```yaml
# ═══════════════════════════════════════════
# <Loc Name> connections
# ═══════════════════════════════════════════

- id: yamaha_<loc>
  module: "yamaha-rcp"
  label: "Yamaha <model> (<Loc Name>)"
  enabled: true
  config:
    host: "<mixer-ip>"
    model: "TF"
    isFirstInit: true

- id: propresenter_<loc>
  module: "renewedvision-propresenter"
  label: "ProPresenter (<Loc Name>)"
  enabled: true
  config:
    host: "<pp-host>"
    port: "<pp-port>"
    pass: "<pp-password>"
    use_sd: "yes"
    sdpass: ""
    sendPresentationCurrentMsgs: "disabled"
    timerPolling: "enabled"

# Add ptz_<loc>, obs_<loc>, atem_<loc> as applicable
```

## Step 4 — Update `surfaces.yaml`

Add entries for each Stream Deck at the new location:

```yaml
surfaces:
  - id: <loc>_xl_main
    type: streamdeck-network
    host: <stream-deck-ip>
    port: 16622
    group_id: <group-id>
    label: "<Loc Name> XL"
    startup_page: <home-page-number>
    grid_size: { cols: 8, rows: 4 }
```

See [add-new-stream-deck.md](add-new-stream-deck.md) for full details.

## Step 5 — Update CLAUDE.md and INVENTORY.md

Update `apps/companion/CLAUDE.md`:

- Add the new connection IDs to the "Connection Naming" section.
- Note any location-specific quirks (different module versions, custom channel mappings).

Update `apps/companion/INVENTORY.md` (or create if it doesn't exist):

- Hardware inventory at the new location.
- Stream Deck serial numbers / IPs.
- AV system IPs and credentials reference (Sealed Secret keys, not actual passwords).

## Step 6 — Document in `locations/`

Create `docs/companion/locations/<loc>.md`:

```markdown
# <Loc Name>

## Overview
- Pi running Companion: <hostname> (<tailnet-ip>)
- Cluster: <cluster-name>
- LAN: <subnet>
- Network notes: ...

## Systems
- Mixer: Yamaha <model> at <ip> — connection `yamaha_<loc>`
- ProPresenter: <version> at <host>:<port> — connection `propresenter_<loc>`
- (etc.)

## Stream Decks
- <model> at <ip> — startup page <N> — surface `<loc>_<role>`

## Pages
- Page <N>: <name> — link to page doc
- (etc.)

## Channel mappings (mixer)
| Channel | Role |
|---------|------|
| ... | ... |

## OBS scenes
- Main / Camera / Slides / etc.

## Service flow
(any location-specific service flow notes)
```

## Step 7 — Validate

```bash
python3 apps/companion/scripts/companion-deploy.py generate > /tmp/check.json
# Verify no errors. Check that:
# - All <loc> connections appear
# - All <loc> pages appear
# - Surface entries are complete
```

## Step 8 — Commit + push

```bash
git add apps/companion/config/ apps/companion/CLAUDE.md docs/companion/locations/<loc>.md
git commit -m "feat: <loc> location bring-up"
git push
```

Watch the deploy:

```bash
ssh <new-loc-pi> "kubectl logs -n companion job/companion-deploy -f"
```

Open the new Stream Deck — buttons should appear.

## Common pitfalls

- **Hardcoded location name in YAML expressions**: search the config for the existing location name (`yibc` / `saitama`) before copying — replace all instances.
- **Page number conflict**: another location already uses a number in your chosen range. Always pick from a 10-page block reserved per the [page registry](../pages/README.md).
- **Forgot to update `surfaces.yaml`**: Stream Decks at the new location won't auto-register. They'll show their setup screen.
- **Channel mappings differ between mixer models**: TF1 vs TF5 have different default channel assignments. Don't assume X=11 = Pastor everywhere.

## Cross-references

- Page registry: [pages/README.md](../pages/README.md)
- Add Stream Deck: [add-new-stream-deck.md](add-new-stream-deck.md)
- Add system: [add-new-system.md](add-new-system.md)
- Connection naming: [connection-ids.md](../reference/connection-ids.md)
- Per-location docs: `docs/companion/locations/`
