# Page 20: PTZ Encoder Control (YIBC / Stream Deck+)

Source: `apps/companion/config/pages/yibc/plus-page01-ptz.yaml`

## Purpose

Encoder-driven PTZ control with named preset buttons. The pan/tilt encoders use a **move + wait + stop** pattern so a single rotation increment moves the camera for a duration proportional to the speed setting, then stops. The wait expression `10 + ($(internal:custom_ptz_speed) - 1) * 15` produces 10ms at speed=1, 355ms at speed=24.

Pairs with [Page 21 D-Pad](yibc-plus-21-dpad.md). E3 PAGE encoder flips between the two.

The Stream Deck+ reports as 4×4: rows 0-1 are physical buttons, row 2 is the LCD strip (pressable buttons), row 3 is encoder labels (not visible — encoders use their own dedicated label slot).

## Grid layout

```
┌──────────┬──────────┬──────────┬──────────┐
│ Cross    │ Wide     │ Sermon   │ ZOOM +   │
│ 十字架    │ ワイド    │ 説教     │ ズーム    │
├──────────┼──────────┼──────────┼──────────┤
│ Pulpit   │ Worship  │ Guitar   │ ZOOM -   │
│ 説教台    │ 賛美     │ ギター    │ ズーム    │
├──────────┼──────────┼──────────┼──────────┤
│ PAN ◄►   │ TILT ▲▼  │ SPD 12   │ PAGE ►   │ ← LCD strip
├──────────┼──────────┼──────────┼──────────┤
│ [PAN]    │ [TILT]   │ [SPD]    │ [PAGE]   │ ← encoders
└──────────┴──────────┴──────────┴──────────┘
```

## Button-by-button (rows 0-2)

| Pos | Label EN / JP | Press | Long Press | Release | Target | Notes |
|-----|---------------|-------|------------|---------|--------|-------|
| 0/0 | Cross / 十字架 | `ptz:recallPreset {presetAsNumber: 0}` | `ptz:setPreset {presetAsNumber: 0}` | — | PTZ | Hold to overwrite preset |
| 0/1 | Wide / ワイド | `ptz:recallPreset {presetAsNumber: 1}` | `ptz:setPreset {presetAsNumber: 1}` | — | PTZ | |
| 0/2 | Sermon / 説教 | `ptz:recallPreset {presetAsNumber: 2}` | `ptz:setPreset {presetAsNumber: 2}` | — | PTZ | |
| 0/3 | ZOOM + / ズーム | `ptz:zoomI` | — | `ptz:zoomS` (release) | PTZ | Hold to zoom in, release to stop |
| 1/0 | Pulpit / 説教台 | `ptz:recallPreset {presetAsNumber: 3}` | `ptz:setPreset {presetAsNumber: 3}` | — | PTZ | |
| 1/1 | Worship / 賛美 | `ptz:recallPreset {presetAsNumber: 4}` | `ptz:setPreset {presetAsNumber: 4}` | — | PTZ | |
| 1/2 | Guitar / ギター | `ptz:recallPreset {presetAsNumber: 5}` | `ptz:setPreset {presetAsNumber: 5}` | — | PTZ | |
| 1/3 | ZOOM − / ズーム | `ptz:zoomO` | — | `ptz:zoomS` (release) | PTZ | Press-and-hold to zoom out |
| 2/0 | PAN ◄► (LCD label) | — | — | — | — | Static label |
| 2/1 | TILT ▲▼ (LCD label) | — | — | — | — | Static label |
| 2/2 | SPD `$(custom_ptz_speed)` | — | — | — | — | Live speed display |
| 2/3 | PAGE ► | `internal:set_page {page: 21}` | — | — | Companion | Hop to D-Pad |

## Encoder configuration

| Enc | Label | Rotate CW | Rotate CCW | Press | Long Press | Notes |
|-----|-------|-----------|------------|-------|------------|-------|
| E0 | PAN | `ptz:right` → `wait` → `ptz:stop` | `ptz:left` → `wait` → `ptz:stop` | `ptz:home` | `ptz:stop` | Wait time = `10 + (speed-1)*15` ms |
| E1 | TILT | `ptz:up` → `wait` → `ptz:stop` | `ptz:down` → `wait` → `ptz:stop` | `ptz:home` | `ptz:stop` | Same pattern as PAN |
| E2 | SPD | `ptz:ptSpeedU` + `custom_ptz_speed += 1` (max 24) | `ptz:ptSpeedD` + `custom_ptz_speed -= 1` (min 1) | `ptz:ptSpeedSet {speed: 12}` + reset var to "12" | `ptz:stop`+`ptz:zoomS` | Press = recenter speed at 12 |
| E3 | PAGE | `internal:set_page {page: 21}` | `internal:set_page {page: 21}` | `internal:set_page {page: 20}` | — | Either rotation flips, press goes home |

The PAN/TILT pattern is critical — without the trailing `ptz:stop`, the camera continues moving indefinitely. See [troubleshooting](../reference/troubleshooting.md#encoder-rotation-never-stops).

The encoder action sets are keyed `rotate_cw` / `rotate_ccw` in the YAML; the generator translates these to Companion's internal `rotate_left` / `rotate_right` action set names.

## Connection dependencies

| Connection ID | Required for | Status if missing |
|---------------|--------------|-------------------|
| `ptz` | Every button + encoder except PAGE | Buttons appear active, no camera response |

## Known issues / TODOs

- **Preset 6 (Baptism) has no dedicated button** on this page. Use [Page 21 D-Pad](yibc-plus-21-dpad.md) preset selectors (E0/E1) which can scroll to preset 6.
- **Speed display vs camera state**: `custom_ptz_speed` is a Companion-side mirror of camera speed. If something else changes camera speed (e.g. a different controller), this variable drifts. Press E2 to resync to 12.
- **No feedback styles** on preset buttons — there is no way to know which preset is currently active because the PTZ module doesn't expose that as a feedback.

## Related

- Sibling page: [Page 21 D-Pad](yibc-plus-21-dpad.md)
- Other YIBC page: [Page 30 Ops](yibc-mk2-30-ops.md) (MK2)
- PTZ action IDs: [reference/action-ids.md](../reference/action-ids.md#ptzoptics-visca)
- Variables: [reference/variables.md](../reference/variables.md)
