# Stream Deck MK2

Elgato Stream Deck MK2 — compact LCD-button surface. Currently deployed at YIBC for service operations (ProPresenter advance + audio control).

## At a glance

| Attribute | Value |
|---|---|
| Serial | `A00SA5432NCLFZ` |
| Surface group ID | `streamdeck:A00SA5432NCLFZ` |
| Grid | 5 columns × 3 rows = **15 buttons** |
| Encoders | none |
| LCD strip | none |
| Per-button display | 72 × 72 px LCD per key |
| Connection | Stream Deck Network module (Elgato outbound TCP, port `5343`) |
| Current location | YIBC |
| Current LAN IP | `192.168.1.43` |
| Startup page | **30** |

## Hardware notes

- 15 identical full-color LCD keys; no knobs, no touch strip.
- Press is binary; supports `down`, `up`, `long_press` action sets.
- Multi-step buttons (e.g. DUCK / UNDUCK toggle) supported via Companion's standard `steps` mechanism. The MK2 page uses this for the duck/unduck pair.

## Pages

Pages 30–39 live in [`apps/companion/config/pages/yibc/`](../../../apps/companion/config/pages/yibc/):

| Page | File | Purpose |
|---|---|---|
| 30 | `mk2-page01-ops.yaml` | Service operations — OBS stream/record, OBS scene cuts, ProPresenter prev/next/clear, master mute, smooth -20 dB duck. **Default.** |

### Layout summary (page 30)

```
Row 0: [STREAM] [REC   ] [Main  ] [Camera] [Clock ]
Row 1: [PREV  ] [NEXT  ] [CLR A ] [      ] [      ]
Row 2: [Mute  ] [DUCK  ] [      ] [      ] [→ PTZ ]
```

## Action ID notes (this device)

| Prefix | Module | Connection ID |
|---|---|---|
| `obs:` | OBS WebSocket | not yet declared in `connections.yaml` — uses `toggle_streaming`, `toggle_recording`, `set_current_scene` |
| `propresenter_yibc:` | `renewedvision-propresenter` | `propresenter_yibc` (`192.168.1.2:1025`) — uses `last`, `next`, `clearall` |
| `yamaha_yibc:` | `yamaha-rcp` | `yamaha_yibc` (TF5 at `192.168.1.54`) — uses `MIXER_Current/St/Fader/On`, `MIXER_Current/Mix/Fader/On`, and `.../Fader/Level` |
| `internal:` | Companion built-ins | `wait`, `step_delta` (NOT `step_next` / `step_set`) |

## Notable patterns on page 30

### Multi-bus mute toggle
Master Mute fires two RCP commands in one press: stereo master (`X: 1`) + aux 17 front-fill (`X: 17`), both with `Val: "Toggle"`. Feedback indicator reads stereo master state only (`Val: 0` = muted).

### Smooth duck via stepped fades
DUCK button uses Companion `steps`:
- **Step 0 (DUCK -20dB):** 20 stepped `Fader/Level` commands with 50 ms `internal:wait` between each, fading master 0 → -20 dB and aux 17 -6 → -26 dB. Ends with `internal:step_delta amount: 1` to advance to step 1.
- **Step 1 (UNDUCK Restore):** mirror sequence in reverse. Ends with `internal:step_delta amount: -1` to return to step 0.
- Total: 80 RCP commands per fade direction (40 level sets + 20 waits, doubled for two buses). TF5's network stack handles this rate.

Yamaha TF fader scale recap: `100 units = 1 dB`, `0 = 0 dB`, `-32768 = -∞ dB`. Aux 17 maintains -600 unit (-6 dB) offset relative to master throughout the fade.

### Known limitation
Duck assumes starting position 0 dB master / -6 dB aux 17. If the mixer was already ducked when Companion starts, the first press jumps levels before fading. Workaround: recall a known scene before using duck. Future: read actual fader level via auto-create variable feedback before computing the fade.

## Quirks

- After config import, the deck may briefly show the IP/Setup screen until `surfaces.outbound.add` re-binds it. The deploy job handles this.
- No encoders → no `rotate_left` / `rotate_right` action sets needed.

## Cross-references

- Location: [YIBC](../locations/yibc.md)
- Page source: [`apps/companion/config/pages/yibc/mk2-page01-ops.yaml`](../../../apps/companion/config/pages/yibc/mk2-page01-ops.yaml)
- Sister deck (same location): [Stream Deck+](stream-deck-plus.md)
- Surfaces source: [`apps/companion/config/surfaces.yaml`](../../../apps/companion/config/surfaces.yaml)
