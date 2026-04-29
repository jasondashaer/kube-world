# Stream Deck+

Elgato Stream Deck+ — hybrid surface with LCD buttons, an LCD touch strip, and four rotary encoders. Currently deployed at YIBC for PTZ control.

## At a glance

| Attribute | Value |
|---|---|
| Serial | `A00WA5241MWHZB` |
| Surface group ID | `streamdeck:A00WA5241MWHZB` |
| Logical grid | 4 columns × 4 rows |
| Physical layout | rows 0–1 = LCD buttons, row 2 = LCD strip zones, row 3 = rotary encoders |
| Encoders | 4 (rotate + push + long-press) |
| LCD strip | 4 pressable zones, narrower aspect than buttons |
| Connection | Stream Deck Network module (Elgato outbound TCP, port `5343`) |
| Current location | YIBC |
| Current LAN IP | `192.168.1.42` |
| Startup page | **20** |

## Logical grid mapping

Companion reports the Plus as **4 × 4** but the rows mean different things:

| Row | Hardware | YAML representation | Press? | Rotate? |
|---|---|---|---|---|
| 0 | Top LCD buttons (4) | `buttons` with `row: 0` | yes | — |
| 1 | Bottom LCD buttons (4) | `buttons` with `row: 1` | yes | — |
| 2 | LCD touch-strip zones (4) | `buttons` with `row: 2` | yes (touch) | — |
| 3 | Rotary encoders (4) | `encoders` with `encoder: 0..3` | yes (push) | yes |

The LCD strip zones (row 2) are addressed exactly like buttons — with `style.text` + `actions.down` — but render in a narrower aspect, so keep labels short (e.g. `PAN ◄►`, `SPD 12`).

## Encoder action sets

Encoder actions support these keys:

| Key | Trigger | Notes |
|---|---|---|
| `rotate_left` | Counter-clockwise click | **Use this name** — NOT `rotate_ccw`. The import layer normalizes to `rotate_left` / `rotate_right`. |
| `rotate_right` | Clockwise click | Same — NOT `rotate_cw`. |
| `down` | Knob press | |
| `up` | Knob release | |
| `long_press` | Held press | |

The connection that owns the encoder must have `rotaryActions: true` set in its surface config (the importer adds this automatically when it sees encoder action sets).

### Move + wait + stop pattern

For motorized control (PTZ pan/tilt), each rotary click sends a move command, waits a speed-scaled duration, then sends stop:

```
rotate_right:
  - action: ptz:right
  - action: internal:wait
    options: { time: "10 + ($(internal:custom_ptz_speed) - 1) * 15" }
  - action: ptz:stop
```

Without the trailing `stop`, the camera continues moving after the rotation event ends. This pattern is used on YIBC page 20 encoders 0 (PAN) and 1 (TILT). See [`apps/companion/config/pages/yibc/plus-page01-ptz.yaml`](../../../apps/companion/config/pages/yibc/plus-page01-ptz.yaml).

## Pages

Pages 20–29 live in [`apps/companion/config/pages/yibc/`](../../../apps/companion/config/pages/yibc/):

| Page | File | Purpose |
|---|---|---|
| 20 | `plus-page01-ptz.yaml` | PTZ encoder control — Pan/Tilt/Speed/Page knobs + preset buttons + zoom. **Default.** |
| 21 | `plus-page02-dpad.yaml` | PTZ d-pad — arrow buttons + preset selector knobs (rotate to scroll, press to recall). |

## Action ID notes (this device)

| Prefix | Module | Connection ID |
|---|---|---|
| `ptz:` | `ptzoptics-visca` | `ptz` (`192.168.1.113:5678`) |
| `internal:` | Companion built-ins | uses `set_page`, `custom_variable_set_value`, `custom_variable_set_expression`, `wait` |

## Quirks

- LCD strip zones (row 2) accept touch and behave as buttons, but visually they are part of one continuous strip — the four `style.text` values render as four labeled segments.
- The Plus's encoder hardware reports rotation as discrete clicks, not continuous degrees. One click = one `rotate_left` or `rotate_right` event.
- After import, surfaces may show the IP/Setup screen until re-bound; the deploy job handles this.

## Cross-references

- Location: [YIBC](../locations/yibc.md)
- Pages source: [`apps/companion/config/pages/yibc/plus-*.yaml`](../../../apps/companion/config/pages/yibc/)
- Surfaces source: [`apps/companion/config/surfaces.yaml`](../../../apps/companion/config/surfaces.yaml)
