# Page 21: PTZ D-Pad (YIBC / Stream Deck+)

Source: `apps/companion/config/pages/yibc/plus-page02-dpad.yaml`

## Purpose

Game-controller-style camera nudge interface for operators who prefer arrow buttons over encoders. Adds two **preset selector encoders** (E0, E1) that scroll a list of presets and recall on press — giving fast access to all 7 presets without dedicating 7 buttons.

Pairs with [Page 20 PTZ Encoder Control](yibc-plus-20-ptz.md). E3 PAGE flips back.

## Grid layout

```
┌──────────┬──────────┬──────────┬──────────┐
│ ZOOM -   │   ▲      │ ZOOM +   │ Wide     │
│ ズーム    │  (UP)    │ ズーム    │ ワイド    │
├──────────┼──────────┼──────────┼──────────┤
│   ◄      │   ▼      │   ►      │ HOME     │
│ (LEFT)   │ (DOWN)   │ (RIGHT)  │ ホーム    │
├──────────┼──────────┼──────────┼──────────┤
│ <name_0> │ <name_1> │ SPD 12   │ PAGE ►   │ ← LCD (pressable)
├──────────┼──────────┼──────────┼──────────┤
│ [PST A]  │ [PST B]  │ [SPD]    │ [PAGE]   │ ← encoders
└──────────┴──────────┴──────────┴──────────┘
```

## Button-by-button (rows 0-2)

| Pos | Label | Press | Release | Target | Notes |
|-----|-------|-------|---------|--------|-------|
| 0/0 | ZOOM − / ズーム | `ptz:zoomO` | `ptz:zoomS` | PTZ | Press-hold |
| 0/1 | ▲ | `ptz:up` | `ptz:stop` | PTZ | Continuous tilt up |
| 0/2 | ZOOM + / ズーム | `ptz:zoomI` | `ptz:zoomS` | PTZ | Press-hold |
| 0/3 | Wide / ワイド | `ptz:recallPreset {presetAsNumber: 1}` | — | PTZ | Quick-jump to preset 1 |
| 1/0 | ◄ | `ptz:left` | `ptz:stop` | PTZ | Continuous pan left |
| 1/1 | ▼ | `ptz:down` | `ptz:stop` | PTZ | Continuous tilt down |
| 1/2 | ► | `ptz:right` | `ptz:stop` | PTZ | Continuous pan right |
| 1/3 | HOME / ホーム | `ptz:home` | — | PTZ | Recall home |
| 2/0 | `$(custom_preset_name_0)` | `ptz:recallPreset {isText: true, presetAsText: $(custom_preset_sel_0)}` | — | PTZ | Recalls whichever preset E0 has selected |
| 2/1 | `$(custom_preset_name_1)` | `ptz:recallPreset {isText: true, presetAsText: $(custom_preset_sel_1)}` | — | PTZ | Recalls whichever preset E1 has selected |
| 2/2 | SPD `$(custom_ptz_speed)` | — | — | — | Static display |
| 2/3 | PAGE ► | `internal:set_page {page: 20}` | — | Companion | Back to PTZ Encoder page |

The d-pad arrows use `down` → action and `up` → `ptz:stop`, NOT the encoder move-wait-stop pattern. This means the camera moves continuously while a button is held — released = stop.

## Encoder configuration

| Enc | Label | Rotate CW | Rotate CCW | Press | Long Press |
|-----|-------|-----------|------------|-------|------------|
| E0 | PST | `preset_sel_0 = min(+1, 6)` + recompute `preset_name_0` | `preset_sel_0 = max(-1, 0)` + recompute `preset_name_0` | `ptz:recallPreset {presetAsText: $(preset_sel_0)}` | — |
| E1 | PST | `preset_sel_1 = min(+1, 6)` + recompute `preset_name_1` | `preset_sel_1 = max(-1, 0)` + recompute `preset_name_1` | `ptz:recallPreset {presetAsText: $(preset_sel_1)}` | — |
| E2 | SPD | `ptz:ptSpeedU` + `ptz_speed = min(+1, 24)` | `ptz:ptSpeedD` + `ptz_speed = max(-1, 1)` | `ptz:ptSpeedSet {speed: 12}` + var = "12" | `ptz:stop`+`ptz:zoomS` |
| E3 | PAGE | `internal:set_page {page: 20}` | `internal:set_page {page: 20}` | `internal:set_page {page: 20}` | — |

### Preset name lookup expression

E0 and E1 use a chained ternary inside `internal:custom_variable_set_expression` to translate the integer index into a label. The full expression on each rotate action:

```
$(internal:custom_preset_sel_0) == 0 ? 'Cross'
: $(internal:custom_preset_sel_0) == 1 ? 'Wide'
: $(internal:custom_preset_sel_0) == 2 ? 'Sermon'
: $(internal:custom_preset_sel_0) == 3 ? 'Pulpit'
: $(internal:custom_preset_sel_0) == 4 ? 'Worship'
: $(internal:custom_preset_sel_0) == 5 ? 'Guitar'
: 'Baptism'
```

This is duplicated for E1 with `preset_sel_1` / `preset_name_1`. If preset names ever change, all four rotate handlers (E0 CW, E0 CCW, E1 CW, E1 CCW) must be updated.

## Connection dependencies

| Connection ID | Required for | Status if missing |
|---------------|--------------|-------------------|
| `ptz` | All d-pad arrows, zoom, presets, encoder presses | Buttons appear active, camera no-response |

## Known issues / TODOs

- **Hard-coded preset names**: name list is duplicated 4×. Refactor opportunity: lookup table in `variables.yaml` or generator macro.
- **No feedback for current preset**: same limitation as page 20.
- **D-pad move pattern differs from page 20 encoders**: this page uses indefinite move-until-release; page 20 uses fixed-duration moves. Operators may find inconsistent feel — design tradeoff for tactile responsiveness.
- **E3 PAGE press goes to page 20** (consistent with rotate). Page 20's E3 press goes to page 20 (home). So E3 press is a "go-home-from-anywhere" gesture; rotate is a flip.

## Related

- Sibling page: [Page 20 PTZ Encoder Control](yibc-plus-20-ptz.md)
- PTZ action IDs: [reference/action-ids.md](../reference/action-ids.md#ptzoptics-visca)
- Custom variables: [reference/variables.md](../reference/variables.md)
