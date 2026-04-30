# Page 30: Ops (YIBC / Stream Deck MK2)

Source: `apps/companion/config/pages/yibc/mk2-page01-ops.yaml`

## Purpose

Single-page operations console for the MK2 at YIBC. Combines OBS stream/scene control, ProPresenter slide navigation, the ARM pre-service automation chain, a two-button service-close workflow, and a smooth Yamaha TF5 master mute / duck. Designed so one operator can run the entire service from this page when the Plus is being used for camera control.

The page is a 5×3 grid (15 buttons, no encoders).

## Page summary

| Field | Value |
|-------|-------|
| Page number | 30 |
| Name | Ops |
| Device | Stream Deck MK2 (5×3) |
| Source YAML | `apps/companion/config/pages/yibc/mk2-page01-ops.yaml` |
| Sibling page | [Page 31 Segments](yibc-mk2-31-segments.md) (`SEGMENTS →` at 2/4) |
| Mixer connection | `yamaha_yibc` (Yamaha TF5 at `192.168.1.54`) |
| Slide connection | `propresenter_yibc` (`192.168.1.2:1025`) |
| Stream connection | `obs_yibc` |
| Music connection | `spotify_yibc` (used by SVC CLOSE 1) |

## Grid layout

```
┌─────────┬─────────┬─────────┬─────────┬─────────┐
│ STREAM  │   REC   │  Main   │ Camera  │  JST    │
│ ●LIVE   │  ●REC   │ ●Main   │ ●Cam    │ HH:MM:SS│
├─────────┼─────────┼─────────┼─────────┼─────────┤
│  PREV   │  NEXT   │ CLEAR   │ ARM /   │ status  │
│  Slide  │  Slide  │  All    │ DISARM  │ + count │
├─────────┼─────────┼─────────┼─────────┼─────────┤
│ Master  │  DUCK   │ CLOSE 1 │ CLOSE 2 │SEGMENTS │
│  Mute   │ -20dB   │  Start  │ Finish  │   →     │
└─────────┴─────────┴─────────┴─────────┴─────────┘
```

## Button-by-button

### Row 0 — Stream + scenes + clock

| Pos | Label | Press Action | Feedback Trigger | Target | Notes |
|-----|-------|--------------|------------------|--------|-------|
| 0/0 | STREAM | `obs:toggle_streaming` | `obs:streaming` → red `● LIVE` | OBS | `obs_yibc` connection |
| 0/1 | REC | `obs:toggle_recording` | `obs:recording` → red `● REC` | OBS | |
| 0/2 | Main | `obs:set_current_scene {scene: Main}` | `obs:scene_active {scene: Main}` → green `● Main` | OBS | Scene "Main" must exist |
| 0/3 | Camera | `obs:set_current_scene {scene: Camera}` | `obs:scene_active {scene: Camera}` → green `● Cam` | OBS | Scene "Camera" must exist |
| 0/4 | `JST $(internal:time_hms)` | — | — | Companion | Live wall-clock display |

### Row 1 — ProPresenter + ARM chain

| Pos | Label | Press Action | Feedback / Display | Target | Notes |
|-----|-------|--------------|--------------------|--------|-------|
| 1/0 | PREV Slide | `propresenter_yibc:last` | — | ProPresenter | Previous slide |
| 1/1 | NEXT Slide | `propresenter_yibc:next` | — | ProPresenter | Next slide |
| 1/2 | CLEAR All | `propresenter_yibc:clearall` | — | ProPresenter | Clears every layer (slide, audio, props) |
| 1/3 | ARM Service / DISARM | Two-step: see [ARM chain](#arm-chain-button-13) below | Step 0 dim grey; Step 1 red `DISARM` + countdown | ProPresenter + Companion vars | Sets `service_armed`, drives `service_mode` |
| 1/4 | status pad | — | `$(internal:custom_service_mode)` + `$(ProPresenter__YIBC_:video_countdown_timer)` | Companion | Live mode + countdown readout |

### Row 2 — Audio + service close + nav

| Pos | Label | Press Action | Feedback / Display | Target | Notes |
|-----|-------|--------------|--------------------|--------|-------|
| 2/0 | Master Mute | `yamaha_yibc:MIXER_Current/St/Fader/On {X:1, Val:Toggle}` AND `MIXER_Current/Mix/Fader/On {X:17, Val:Toggle}` | `St/Fader/On {X:1, Val:0}` → red `MUTE` | Yamaha TF5 | Toggles BOTH stereo master and Mix17 (front-fill) atomically |
| 2/1 | DUCK -20dB / UNDUCK | Step 0: 20-step fade ST 0→−2000 + Mix17 −600→−2600; Step 1: reverse | Two-step toggle (DUCK ↔ UNDUCK) | Yamaha TF5 | See [Smooth fade duck](#smooth-fade-duck-button-21) |
| 2/2 | CLOSE 1 Start | See [SVC CLOSE 1](#svc-close-1-start-button-22) | — | TF5 + Spotify | Begins underscore-music close flow |
| 2/3 | CLOSE 2 Finish | See [SVC CLOSE 2](#svc-close-2-finish-button-23) | — | TF5 + ProPresenter + OBS | Closing graphic + record-bus fade + stop stream/rec |
| 2/4 | SEGMENTS → | `internal:set_page {controller: self, page: 31}` | — | Companion | Jump to [Page 31 Segments](yibc-mk2-31-segments.md) |

## ARM chain (button 1/3)

Two-step pre-service automation arm. Step 0 (dim grey, `ARM Service`) is the idle state. Pressing it executes the arm sequence and advances to step 1.

**Step 0 → ARM (down actions):**

1. `internal:custom_variable_set_value {name: service_armed, value: 1}`
2. `propresenter_yibc:clockReset {clockIndex: 0}`
3. `propresenter_yibc:clockStart {clockIndex: 0}`
4. `internal:custom_variable_set_value {name: service_mode, value: Armed}`
5. `internal:step_delta {amount: 1}` (advance to step 1)

**Step 1 → DISARM (red `DISARM` + live countdown):**

Display: `DISARM\n$(ProPresenter__YIBC_:video_countdown_timer)` — shows ProPresenter clock 0 ticking down.

1. `internal:custom_variable_set_value {name: service_armed, value: 0}`
2. `propresenter_yibc:clockStop {clockIndex: 0}`
3. `internal:custom_variable_set_value {name: service_mode, value: Ready}`
4. `internal:step_delta {amount: -1}` (return to step 0)

`service_armed=1` is the gate the chained automation triggers watch for. Auto-disarm on countdown reaching 0 is wired in `triggers.yaml` (not on this button) — see [reference/triggers.md](../reference/triggers.md). The status pad at 1/4 mirrors `service_mode` and the countdown so the operator has a single glance at chain state without leaving this page.

## Smooth fade duck (button 2/1)

The duck button uses Companion's `steps` mechanism to alternate between DUCK and UNDUCK on each press. Each step contains a 20-step fader ramp with `internal:wait {time: 50}` between each step → **20 × 50ms = 1000ms** total fade duration.

| Bus | Channel | Start (0dB nominal) | End (−20dB) | Offset |
|-----|---------|---------------------|-------------|--------|
| Stereo Master (St) | X=1 | 0 | −2000 | — |
| Mix 17 (front-fill) | X=17 | −600 | −2600 | maintains −6dB offset |

The dual-bus offset preserves the FOH/front-fill mix balance throughout the fade. See [reference/smooth-fades.md](../reference/smooth-fades.md) for the design rationale.

## SVC CLOSE 1 Start (button 2/2)

Stages the close: snapshot levels, fade master to −∞, start an underscore-music playlist, fade music up to a "talking under music" level (−10dB).

**Sequence:**

1. Snapshot pre-close master + record-bus levels into `pre_close_master_level` / `pre_close_mix_level` custom variables.
2. Set `close_stage = "Closing-Underscore"`.
3. **10-step master fade to −∞** over ~500ms (`St/Fader/Level X:1` from 0 → −800 → −1500 → −2300 → −3200 → −32768).
4. `spotify_yibc:playPlaylist` with URI **`spotify:playlist:PLACEHOLDER_PLAYLIST_URI`** — operator-configured, see [guides/secrets-and-credentials.md](../guides/secrets-and-credentials.md).
5. `internal:wait {time: 1500}` — let Spotify start.
6. **30-step slow fade up to −10dB** over ~6s (`St/Fader/Level X:1` from −3000 to −1000, 200ms steps).

End state: master at −10dB with Spotify underscore playing. Pastor / closing speaker can talk over the bed. Record/stream still running.

## SVC CLOSE 2 Finish (button 2/3)

Concludes the close: trigger ProPresenter closing graphic, hold 12s, fade record bus to −∞, stop stream and recording. Music in the room stays up.

**Sequence:**

1. Master to closing target: `yamaha_yibc:MIXER_Current/St/Fader/Level {X:1, Val: $(internal:custom_closing_target_db_units)}` — defaults to −300 (−3dB).
2. Fire ProPresenter closing graphic: `propresenter_yibc:pro7TriggerMacro {pro7MacroUUID: "PLACEHOLDER_CLOSING_GRAPHIC_MACRO"}` — UUID placeholder, see [guides/secrets-and-credentials.md](../guides/secrets-and-credentials.md).
3. `internal:wait {time: 12000}` — hold the graphic on stream/recording for 12s.
4. **4-step record-bus fade to −∞** over ~400ms: `MIXER_Current/Mix/Fader/Level X: $(internal:custom_record_bus_idx)` from −800 → −1600 → −2400 → −32768. The configured record bus index is set per-location — see [reference/yamaha-rcp-namespace.md](../reference/yamaha-rcp-namespace.md).
5. `propresenter_yibc:clearall` — clear all PP layers.
6. `internal:wait {time: 800}`.
7. `obs_yibc:stop_recording`.
8. `obs_yibc:stop_streaming`.
9. Set `close_stage = "Stopped"`, `service_mode = "Off"`.

The room music (Spotify underscore from CLOSE 1) keeps playing through the master — only the record/stream bus is silenced before the OBS stop calls. This is intentional: people are still in the room.

## Connection dependencies

| Connection ID | Required for | Status if missing |
|---------------|--------------|-------------------|
| `yamaha_yibc` | Master Mute, DUCK, mute feedback, both CLOSE buttons | RCP commands fail silently |
| `propresenter_yibc` | PREV / NEXT / CLEAR All, ARM clock, CLOSE 2 macro + clearall | Buttons no-op; countdown variable stays empty |
| `obs_yibc` | STREAM / REC / Main / Camera, CLOSE 2 stop calls | Buttons greyed; feedbacks never trigger |
| `spotify_yibc` | CLOSE 1 playlist start | Music stays at −∞ after master fade-down |

## Encoder configuration

N/A — MK2 has no encoders.

## Variables referenced

| Variable | Set by | Read by |
|----------|--------|---------|
| `service_armed` | ARM step 0 / DISARM step 1 | `triggers.yaml` chain gate |
| `service_mode` | ARM, DISARM, CLOSE 2 | Status pad 1/4, page 40 status display, page 31 status pad |
| `pre_close_master_level`, `pre_close_mix_level` | CLOSE 1 (snapshot) | Future restore-from-close trigger (TBD) |
| `close_stage` | CLOSE 1 / CLOSE 2 | Trigger / observability |
| `closing_target_db_units` | (operator-set, see [variables.md](../reference/variables.md)) | CLOSE 2 master target |
| `record_bus_idx` | (operator-set per location) | CLOSE 2 record-bus fade |
| `ProPresenter__YIBC_:video_countdown_timer` | ProPresenter clock 0 | DISARM display + status pad |

## Live-test plan

For each button, see the matching step in [guides/live-test-runbook.md](../guides/live-test-runbook.md):

- STREAM / REC / Main / Camera — OBS connection smoke test.
- ARM / DISARM — verify `service_armed` flips, ProPresenter clock 0 resets and counts down, status pad mirrors mode.
- CLOSE 1 — confirm master fade-down audible, Spotify URI placeholder is replaced before live use, fade-up settles at −10dB.
- CLOSE 2 — confirm Pro7 macro UUID placeholder is replaced, stream and recording actually stop, room music stays audible.
- DUCK / UNDUCK — confirm 1s smooth fade and Mix17 offset preserved.

## Known issues / TODOs

- **Spotify playlist URI is a placeholder** (`spotify:playlist:PLACEHOLDER_PLAYLIST_URI`). Pressing CLOSE 1 in production without replacing it will fail the `playPlaylist` call. See [guides/secrets-and-credentials.md](../guides/secrets-and-credentials.md).
- **ProPresenter closing-graphic macro UUID is a placeholder** (`PLACEHOLDER_CLOSING_GRAPHIC_MACRO`). CLOSE 2 will run the audio fade and OBS stops but no graphic will appear until the real UUID is set.
- **CLOSE 1 snapshot is a stub.** `pre_close_master_level` / `pre_close_mix_level` are currently set to a constant `0` expression — there is no live-read of the mixer's pre-close state. A future trigger should restore from these on cancel.
- **DUCK depth tied to Mix17**: if the front-fill aux is not Mix bus 17 on this TF5, the duck will affect the wrong bus. Verify channel assignments at install.
- **No CANCEL CLOSE button** — once CLOSE 1 fires, the only way back is manual fader adjustment. Consider adding a CLOSE-CANCEL pad in a future revision.

## Cross-references

- Source YAML: [`apps/companion/config/pages/yibc/mk2-page01-ops.yaml`](../../../apps/companion/config/pages/yibc/mk2-page01-ops.yaml)
- Sibling page on this surface: [Page 31 Segments](yibc-mk2-31-segments.md)
- ARM-gated automation chain: [reference/triggers.md](../reference/triggers.md)
- Scene strategy (segment context for ARM/CLOSE flow): [guides/scene-strategy.md](../guides/scene-strategy.md)
- Record-bus and fader scaling: [reference/yamaha-rcp-namespace.md](../reference/yamaha-rcp-namespace.md)
- Spotify URI + Pro7 macro UUID placeholders: [guides/secrets-and-credentials.md](../guides/secrets-and-credentials.md)
- Live-test plan for these buttons: [guides/live-test-runbook.md](../guides/live-test-runbook.md)
- Variables catalogue: [reference/variables.md](../reference/variables.md)
- Smooth fades design: [reference/smooth-fades.md](../reference/smooth-fades.md)
- Connection IDs: [reference/connection-ids.md](../reference/connection-ids.md)
- Action IDs: [reference/action-ids.md](../reference/action-ids.md)
- Companion subsystem conventions: [`apps/companion/CLAUDE.md`](../../../apps/companion/CLAUDE.md)
