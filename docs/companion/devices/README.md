# Companion Devices

Stream Decks attached to Companion via the Elgato Stream Deck Network module. Each device makes outbound TCP to Companion (`hostNetwork: true` Pod) on port `5343`.

## Device matrix

| Serial | Model | Location | Startup page | Grid | Encoders | LCD strip | Spec |
|---|---|---|---|---|---|---|---|
| `A00NA53835A5F1` | Stream Deck XL | Saitama | 40 | 8 × 4 = 32 | — | — | [stream-deck-xl.md](stream-deck-xl.md) |
| `A00WA5241MWHZB` | Stream Deck+ | YIBC | 20 | 4 × 4 (logical) | 4 (row 3) | yes (row 2) | [stream-deck-plus.md](stream-deck-plus.md) |
| `A00SA5432NCLFZ` | Stream Deck MK2 | YIBC | 30 | 5 × 3 = 15 | — | — | [stream-deck-mk2.md](stream-deck-mk2.md) |

Source of truth: [`apps/companion/config/surfaces.yaml`](../../../apps/companion/config/surfaces.yaml).

## Surface group IDs

Companion identifies network-attached Stream Decks with the form `streamdeck:<SERIAL>`. The surface `group_id` is what `surfaces.outbound.add` and the import re-assignment use to map a physical device to a startup page. The `address` field in `surfaces.yaml` is the device's last-known LAN IP — informational; the actual connection is initiated by the deck outbound to Companion.

## Network Dock surface

The Stream Deck Network module shows up in Companion's Surfaces tab as **two entries per physical deck**:

1. The actual `streamdeck:<SERIAL>` surface (the deck itself).
2. A `Stream Deck Network Dock` parent surface (the module's logical "host"). This is normal — do not delete it; it's how Companion routes outbound TCP from the module to specific decks.

Only the per-serial entries get explicit page assignments. The Network Dock entry is a passthrough.

## Connection mechanics

- The deck originates the TCP session to Companion's host on port `5343`.
- Pi-edge-1 runs Companion with `hostNetwork: true`, so the deck connects to the Pi's LAN IP, not a Pod IP.
- After every config import, Companion re-applies surface assignments via `surfaces.outbound.add` (or its current tRPC equivalent). Without this, decks may revert to their setup screen post-import.
- Quirk: an import that wipes surfaces causes the deck LCDs to display the IP/Setup screen until reassigned. Re-running the deploy job (or the `surfaces.yaml` post-import hook) restores them.

## Page-range convention

Each device + location gets a 10-page range so a single import never collides:

| Range | Device | Location |
|---|---|---|
| 20–29 | Stream Deck+ | YIBC |
| 30–39 | Stream Deck MK2 | YIBC |
| 40–49 | Stream Deck XL | Saitama |

## Cross-references

- Locations: [`docs/companion/locations/`](../locations/)
- Pipeline: [`docs/companion/PIPELINE.md`](../PIPELINE.md)
- Surfaces source: [`apps/companion/config/surfaces.yaml`](../../../apps/companion/config/surfaces.yaml)
