# Page 30: Ops (YIBC / Stream Deck MK2)

Source: `apps/companion/config/pages/yibc/mk2-page01-ops.yaml`

## Purpose

Single-page operations console for the MK2 at YIBC. Combines OBS stream/scene control, ProPresenter slide navigation, and a single-button Yamaha TF5 master mute / smooth-fade duck. Designed so one operator can run the entire service from this page when the Plus is being used for camera control.

The page is a 5×3 grid (15 buttons, no encoders).

## Grid layout

```
┌─────────┬─────────┬─────────┬─────────┬─────────┐
│ STREAM  │   REC   │  Main   │ Camera  │ time    │
│ ●LIVE   │  ●REC   │ ●Main   │ ●Cam    │ HH:MM:SS│
├─────────┼─────────┼─────────┼─────────┼─────────┤
│  PREV   │  NEXT   │ CLEAR   │         │         │
│  Slide  │  Slide  │  All    │         │         │
├─────────┼─────────┼─────────┼─────────┼─────────┤
│ Master  │  DUCK   │         │         │         │
│  Mute   │ -20dB   │         │         │         │
└─────────┴─────────┴─────────┴─────────┴─────────┘
```

## Button-by-button

| Pos | Label | Press Action | Long Press | Feedback Trigger | Target | Notes |
|-----|-------|--------------|------------|------------------|--------|-------|
| 0/0 | STREAM | `obs:toggle_streaming` | — | `obs:streaming` → red `● LIVE` | OBS | OBS connection not yet defined in connections.yaml — placeholder |
| 0/1 | REC | `obs:toggle_recording` | — | `obs:recording` → red `● REC` | OBS | Same caveat as STREAM |
| 0/2 | Main | `obs:set_current_scene {scene: Main}` | — | `obs:scene_active {scene: Main}` → green `● Main` | OBS | Scene "Main" must exist in OBS |
| 0/3 | Camera | `obs:set_current_scene {scene: Camera}` | — | `obs:scene_active {scene: Camera}` → green `● Cam` | OBS | Scene "Camera" must exist |
| 0/4 | `$(internal:time_hms)` | — | — | — | Companion | Live wall-clock display |
| 1/0 | PREV Slide | `propresenter_yibc:last` | — | — | ProPresenter | Previous slide |
| 1/1 | NEXT Slide | `propresenter_yibc:next` | — | — | ProPresenter | Next slide |
| 1/2 | CLEAR All | `propresenter_yibc:clearall` | — | — | ProPresenter | Clears every layer (slide, audio, props, etc.) |
| 1/3 | (blank) | — | — | — | — | Spacer |
| 1/4 | (blank) | — | — | — | — | Spacer |
| 2/0 | Master Mute | `yamaha_yibc:MIXER_Current/St/Fader/On {X:1, Val:Toggle}` AND `MIXER_Current/Mix/Fader/On {X:17, Val:Toggle}` | — | `St/Fader/On {X:1, Val:0}` → red `MUTE` | Yamaha TF5 | Toggles BOTH stereo master and Mix17 (front-fill) atomically |
| 2/1 | DUCK -20dB / UNDUCK | Step 0: 20-step fade ST −0→−2000 + Mix17 −600→−2600; Step 1: reverse | — | — | Yamaha TF5 | Two-step toggle — see Smooth fades below |
| 2/2 | (blank) | — | — | — | — | Spacer |
| 2/3 | (blank) | — | — | — | — | Spacer |
| 2/4 | (blank) | — | — | — | — | Spacer |

## Smooth fade duck (button 2/1)

The duck button uses Companion's `steps` mechanism to alternate between DUCK and UNDUCK on each press. Each step contains a 20-step fader ramp with `internal:wait {time: 50}` between each step → **20 × 50ms = 1000ms** total fade duration.

| Bus | Channel | Start (0dB nominal) | End (−20dB) | Offset |
|-----|---------|---------------------|-------------|--------|
| Stereo Master (St) | X=1 | 0 | −2000 | — |
| Mix 17 (front-fill) | X=17 | −600 | −2600 | maintains −6dB offset |

The dual-bus offset preserves the FOH/front-fill mix balance throughout the fade. Step 0 (DUCK) fades down then `internal:step_delta {amount: 1}` advances to step 1; step 1 (UNDUCK) fades back up then `internal:step_delta {amount: -1}` returns to step 0.

See [reference/smooth-fades.md](../reference/smooth-fades.md) for the design rationale.

## Connection dependencies

| Connection ID | Required for | Status if missing |
|---------------|--------------|-------------------|
| `yamaha_yibc` | Master Mute, DUCK, mute feedback | Buttons appear "active" but RCP commands fail silently |
| `propresenter_yibc` | PREV / NEXT / CLEAR All | Buttons no-op |
| `obs` (not yet defined) | STREAM / REC / Main / Camera | Buttons greyed; feedbacks never trigger |

## Encoder configuration

N/A — MK2 has no encoders.

## Known issues / TODOs

- **OBS connection placeholder**: `connections.yaml` does not yet define an `obs` connection. Row 0 columns 0-3 will be no-ops until added.
- **Empty buttons**: row 1 cols 3-4 and row 2 cols 2-4 are deliberately blank (text=`""`, dark bgcolor) — reserved for future actions.
- **DUCK depth tied to Mix17**: if the front-fill aux is not Mix bus 17 on this TF5, the duck will affect the wrong bus. Verify channel assignments at install.

## Related

- Parent location: [YIBC](../locations/) (TBD)
- Parent device: [Stream Deck MK2](../devices/) (TBD)
- Companion pages: [Page 20 PTZ](yibc-plus-20-ptz.md), [Page 21 D-Pad](yibc-plus-21-dpad.md) (Plus surface, separate device)
- Connection IDs: [reference/connection-ids.md](../reference/connection-ids.md)
- Action IDs: [reference/action-ids.md](../reference/action-ids.md)
