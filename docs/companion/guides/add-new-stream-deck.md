# Guide: Add a New Stream Deck

Bringing a new Stream Deck (any model — Mini, MK2, XL, Plus) into the Companion fleet. The Stream Deck connects to Companion as an **outbound network surface** using the Elgato Stream Deck Network module — Companion never directly owns the USB device on the Pi (it doesn't see the device through `hostNetwork`).

## Prerequisites

- The Stream Deck is a model that supports the **Stream Deck Network** firmware (XL, MK2, Plus, +). Older models without network firmware are not supported.
- Stream Deck firmware is up to date (use Elgato Stream Deck app to check before disconnecting from the configuring computer).
- The Pi running Companion is reachable from the Stream Deck's LAN (typically the same VLAN — Companion uses `hostNetwork: true` so it binds directly to the Pi's LAN IP).
- You know which page (existing or new) the Stream Deck should land on at startup.

---

## Step 1 — Physical setup

1. Power the Stream Deck via USB. Use a wall PSU or a powered hub — the Pi USB ports may not deliver enough current for the larger units.
2. Plug the Stream Deck into the LAN switch (or Wi-Fi via firmware setup if supported). It will display its IP address.
3. Note the Stream Deck's IP address and group ID (visible in the Stream Deck app or on the device's setup screen).

## Step 2 — Configure as a Network surface in firmware

If the Stream Deck has dual-mode firmware (some Plus / + models):

1. Use the Elgato Stream Deck app to switch the device to "Stream Deck Network" mode.
2. Configure the destination as the Companion Pi's LAN IP, port 16622 (or whatever Companion's network surface listener is bound to — verify in `apps/companion/deployment.yaml` ports list).
3. Disconnect from the configuring computer.

Newer Stream Decks ship in network mode by default and don't need this step.

## Step 3 — Register as outbound surface in Companion

Companion needs to know about the Stream Deck. Two ways:

### Option A — Web UI (one-time)

Open `http://<pi-ip>:8000` → Surfaces tab → Add → "Stream Deck Network" / "Elgato Outbound" → enter the Stream Deck's IP. Companion connects and the surface appears.

**Caveat**: this manual registration may be wiped on the next config import. Use option B for persistence.

### Option B — `surfaces.yaml` (persistent, recommended)

Add an entry in `apps/companion/config/surfaces.yaml`:

```yaml
surfaces:
  - id: <unique_id>            # e.g. "yibc_plus_main"
    type: streamdeck-network
    host: 192.168.1.123        # Stream Deck IP
    port: 16622                # default Elgato outbound port
    group_id: <group_id>       # from Stream Deck firmware
    label: "YIBC Plus (Main)"
    startup_page: 20           # which page to land on
    grid_size:
      cols: 4
      rows: 4
```

The `companion-deploy.py` post-import hook reads this file and calls `surfaces.outbound.add` via tRPC for each entry, idempotently.

## Step 4 — Decide the grid + page assignment

| Model | Grid | Page range |
|-------|------|-----------|
| Mini | 3×2 | (none assigned yet) |
| MK2 | 5×3 | 30-39 |
| XL | 8×4 | 40-49 |
| Plus | 4×4 (rows 0-1 buttons, row 2 LCD strip, row 3 encoders) | 20-29 |

Pick a `startup_page` that already exists for the right grid size. If you need a NEW page, follow [add-new-system.md](add-new-system.md) for the page authoring loop.

## Step 5 — Commit + push

```bash
git add apps/companion/config/surfaces.yaml
git commit -m "add: surface entry for new XL at <location>"
git push
```

Wait for Flux + Karmada to reconcile (~1 min). The deploy job runs `companion-deploy.py`, which (a) imports the config, (b) registers all surfaces from `surfaces.yaml`. Watch:

```bash
ssh pi-edge-1 "kubectl logs -n companion job/companion-deploy -f"
```

## Step 6 — Verify

1. Stream Deck should display the configured page within a few seconds of the deploy completing.
2. Press a button — verify the action runs.
3. If the Stream Deck shows IP/Setup screen instead of buttons, see [troubleshooting](../reference/troubleshooting.md#stream-deck-shows-ip--setup-screen-after-import).

## Common pitfalls

- **Surface registered manually disappears after deploy**: use `surfaces.yaml`, not the web UI.
- **Stream Deck stuck on startup screen**: firmware mismatch — re-flash via Elgato app.
- **Buttons land on wrong page**: check `startup_page` in `surfaces.yaml`. The Stream Deck always lands on its surface's startup page after Companion restart.
- **Grid size mismatch**: if you assign an MK2 (5×3) to a page designed for XL (8×4), the extra columns / rows just don't render. Buttons won't error, but the page is broken visually.

## Cross-references

- Surface inventory: `apps/companion/config/surfaces.yaml`
- Page registry: [pages/README.md](../pages/README.md)
- Deploy workflow: [deploy-config-changes.md](deploy-config-changes.md)
- Setup from scratch: [setup-from-scratch.md](setup-from-scratch.md)
