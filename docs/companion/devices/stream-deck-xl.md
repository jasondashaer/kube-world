# Stream Deck XL

Elgato Stream Deck XL — full LCD-button surface, currently deployed at Saitama.

## At a glance

| Attribute | Value |
|---|---|
| Serial | `A00NA53835A5F1` |
| Surface group ID | `streamdeck:A00NA53835A5F1` |
| Grid | 8 columns × 4 rows = **32 buttons** |
| Encoders | none |
| LCD strip | none |
| Per-button display | 72 × 72 px LCD per key |
| Connection | Stream Deck Network module (Elgato outbound TCP, port `5343`) |
| Current location | Saitama |
| Current LAN IP | `192.168.1.41` (verify per visit — not stable) |
| Startup page | **40** |

## Hardware notes

- All 32 keys are full-color LCD with backlit press; identical hardware per key.
- No knobs, no LCD strip, no haptics. Pure button matrix.
- Image overlays render at 72×72 native; Companion downscales larger images.
- Press is binary; `down`/`up` action lists fire on press / release. Long-press supported.

## Pages

Pages 40–43 live in [`apps/companion/config/pages/saitama/`](../../../apps/companion/config/pages/saitama/):

| Page | File | Purpose |
|---|---|---|
| 40 | `xl-page01-home.yaml` | Home dashboard — status row, scenes, transitions, sub-page nav, PANIC. |
| 41 | `xl-page02-audio.yaml` | TF1 audio mixer — per-channel mute/level, scene recall. |
| 42 | `xl-page03-slides.yaml` | ProPresenter — advance, slide jumps, looks, timer. |
| 43 | `xl-page04-stream.yaml` | OBS + ATEM streaming/recording, Blackmagic recorder. |

Page numbering convention reserves 40–49 for this deck at Saitama; see [device matrix](README.md#page-range-convention).

## Action ID notes (this device)

The XL pages reference these connection prefixes:

| Prefix | Module | Connection ID |
|---|---|---|
| `obs:` | OBS WebSocket (TBD) | not yet declared in `connections.yaml` — see Saitama TODOs |
| `atem:` | Blackmagic ATEM (TBD) | not yet declared |
| `yamaha_saitama:` | `yamaha-rcp` | `yamaha_saitama` (TF1 at `192.168.10.30`) |
| `propresenter_saitama:` | `renewedvision-propresenter` | `propresenter_saitama` (`192.168.68.55:53678`) |
| `internal:` | Companion built-ins | — |

## Quirks

- After config import, the deck briefly returns to its IP/Setup screen until `surfaces.outbound.add` re-binds it. The deploy job handles this automatically.
- DHCP IP is not stable across visits; update `apps/companion/config/surfaces.yaml` and commit when it changes.
- No encoders → no `rotate_left`/`rotate_right` action sets needed; only standard `down`/`up`/`long_press`.

## Cross-references

- Location: [Saitama](../locations/saitama.md)
- Pages source: [`apps/companion/config/pages/saitama/`](../../../apps/companion/config/pages/saitama/)
- Surfaces source: [`apps/companion/config/surfaces.yaml`](../../../apps/companion/config/surfaces.yaml)
