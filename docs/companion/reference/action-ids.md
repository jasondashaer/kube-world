# Action ID Reference

Canonical lookup of every action ID currently in use across the Companion config, plus all module-exposed actions for the modules we connect to. This document is the authoritative source for action IDs in `apps/companion/config/`.

For raw module dumps see [docs/companion/integrations/module-action-reference.md](../integrations/module-action-reference.md). This file curates and annotates them with project-specific semantics.

## Quick index

| Module | Connection IDs in use | In-use page(s) |
|--------|----------------------|----------------|
| `internal` | (always available) | All pages |
| `ptzoptics-visca` | `ptz` | 20, 21 |
| `yamaha-rcp` | `yamaha_yibc`, `yamaha_saitama` | 30, 40, 41 |
| `renewedvision-propresenter` | `propresenter_yibc`, `propresenter_saitama` | 30, 40, 42 |
| `obs` (TBD) | `obs` (not yet defined) | 30, 40, 43 |
| `atem` (TBD) | `atem` (not yet defined) | 40, 43 |
| `homeassistant-server` | `homeassistant` | (none yet) |

Action invocation format in YAML: `<connection_id>:<action_id>`. Example: `yamaha_yibc:MIXER_Current/St/Fader/Level`.

---

## `internal` actions

Companion's built-in actions. Available without any connection.

| Action ID | Options | Notes |
|-----------|---------|-------|
| `wait` | `time` (ms; supports expressions) | Used heavily for fade pacing. Expressions like `"10 + ($(internal:custom_ptz_speed) - 1) * 15"` are valid. |
| `set_page` | `controller` (`"self"` or surface ID), `page` (page number) | Use `"self"` to keep the surface on its current device. |
| `step_delta` | `amount` (signed integer) | Advances button step. `+1` = next step, `-1` = previous. Used for two-step toggles (DUCK/UNDUCK, confirm-shutdown). |
| `custom_variable_set_value` | `name` (variable name without `$()` wrapper), `value` (string) | NOT `variable_set`. Direct value assignment. |
| `custom_variable_set_expression` | `name`, `expression` (Companion expression syntax) | Used for math (`min`, `max`) and ternary chains. |

**Common pitfalls:**
- The action is `custom_variable_set_value` — using `variable_set` silently fails.
- The action is `set_page` — using `page_set` silently fails.
- The action is `step_delta` — there is no `step_next`, `step_set`, etc.

---

## `ptzoptics-visca` actions (connection `ptz`)

Module action IDs are short tokens. Verified against live module:

| Action ID | Description | Options | Notes |
|-----------|-------------|---------|-------|
| `left` | Pan left at current speed | (none) | Continuous — must follow with `stop` |
| `right` | Pan right | (none) | Same |
| `up` | Tilt up | (none) | Same |
| `down` | Tilt down | (none) | Same |
| `home` | Move to home position | (none) | Self-stops |
| `stop` | Halt all motion | (none) | |
| `zoomI` | Zoom in continuous | (none) | Pair with `zoomS` to stop |
| `zoomO` | Zoom out continuous | (none) | |
| `zoomS` | Zoom stop | (none) | |
| `focusN` | Focus near | (none) | |
| `focusF` | Focus far | (none) | |
| `focusS` | Focus stop | (none) | |
| `focusM` | Toggle focus mode (auto/manual) | (none) | |
| `recallPreset` | Recall preset | `isText` (bool), `presetAsNumber` (int) OR `presetAsText` (string with var refs) | If `isText:true`, use `presetAsText` with variable references. If `isText:false`, use `presetAsNumber`. |
| `setPreset` | Save current as preset | `isText` (bool), `presetAsNumber` (int) | Used on `long_press` |
| `ptSpeedU` | Pan/tilt speed up | (none) | Companion-side only — does not query camera state |
| `ptSpeedD` | Pan/tilt speed down | (none) | |
| `ptSpeedSet` | Set pan/tilt speed | `speed` (int 1-24, VISCA scale) | |
| `power` | Camera power toggle | (none) | |
| `custom` | Send raw VISCA command | `cmd` (hex string) | Escape hatch |

**Move-and-stop pattern** (canonical for encoders):

```yaml
rotate_cw:
  - action: ptz:right
  - action: internal:wait
    options: { time: "10 + ($(internal:custom_ptz_speed) - 1) * 15" }
  - action: ptz:stop
```

Without `ptz:stop`, the camera continues moving after the rotation event ends. See [troubleshooting](troubleshooting.md#encoder-rotation-never-stops).

---

## `yamaha-rcp` actions (connections `yamaha_yibc`, `yamaha_saitama`)

Action IDs encode RCP addresses — the colon is replaced with underscore: `MIXER:Current/InCh/Fader/On` becomes `MIXER_Current/InCh/Fader/On`.

### Required connection-init flag

```yaml
- id: yamaha_yibc
  module: "yamaha-rcp"
  config:
    isFirstInit: true   # CRITICAL — see troubleshooting
```

Without `isFirstInit: true`, the module's upgrade scripts crash with `findRcpCmd undefined` on first import.

### Universal options

| Option | Type | Notes |
|--------|------|-------|
| `X` | int | Channel/source (1-based). Supports variables. |
| `Y` | int | Bus/destination (when applicable). Supports variables. |
| `Val` | int / string | For `bool`: `0`=Off (muted), `1`=On (unmuted), `"Toggle"`. For `integer`: numeric value. |
| `Rel` | bool | If `true` and Val is integer, applies as delta. Used for ±1dB nudge buttons. |

### TF-series action IDs in use

| Action ID | Type | Range | Usage |
|-----------|------|-------|-------|
| `MIXER_Current/InCh/Fader/Level` | int | -32768 to 1000 | Input channel fader level. ±100 with `Rel:true` = ±1dB. |
| `MIXER_Current/InCh/Fader/On` | bool | 0/1/Toggle | Input channel mute (0=mute). |
| `MIXER_Current/St/Fader/Level` | int | -32768 to 1000 | Stereo master fader level. |
| `MIXER_Current/St/Fader/On` | bool | 0/1/Toggle | Stereo master mute. |
| `MIXER_Current/Mix/Fader/Level` | int | -32768 to 1000 | Mix bus fader level. X=17 used for front-fill at YIBC. |
| `MIXER_Current/Mix/Fader/On` | bool | 0/1/Toggle | Mix bus mute. |
| `MIXER_Lib/Bank/Scene/Recall` | int | 0-100 | Recall scene. X=bank, Y=A(1)/B(2). |
| `MIXER_Lib/Bank/Scene/Store` | int | 0-100 | Save current state to scene. |

### Mute logic (always inverted)

`Fader/On = 1` means **on / unmuted**. `Fader/On = 0` means **muted**. Feedback styles in our pages always test `Val: 0` (red MUTE indicator when channel is OFF).

### Fader value scale

Non-linear:
- `-32768` = −∞ dB
- `-2000` = −20 dB
- `-600` = −6 dB
- `0` = 0 dB (unity)
- `1000` = +10 dB

Roughly **100 units = 1 dB** in the working range −∞ to 0, but the scale is logarithmic at the extremes. For fades, use linear unit steps in the −2000 to 0 range (where it's approximately linear).

### Other TF actions available (not yet used)

`MIXER_Current/InCh/Label/Name`, `MIXER_Current/InCh/Label/Color`, `MIXER_Current/InCh/ToMix/Level`, `…/ToMix/On`, `…/ToMix/Pan`, `…/ToMix/PrePost`, `…/ToMono/*`, `…/ToFx/*`, `MIXER_Current/StInCh/*`, `MIXER_Current/FxRtnCh/*`, `MIXER_Current/Mtrx/*`, `MIXER_Current/DCA/*`, `MIXER_Current/Mono/*`. See [integrations reference](../integrations/module-action-reference.md#yamaha-rcp-yamaha-rcp-3510).

### Feedback IDs

Every writable action with `rw` access is also a feedback under the same ID. Bool feedbacks return true when current mixer state matches the configured `Val`.

---

## `renewedvision-propresenter` actions (connections `propresenter_yibc`, `propresenter_saitama`)

### Required connection config

```yaml
config:
  sendPresentationCurrentMsgs: "disabled"   # CRITICAL — Pro7 stability
  timerPolling: "enabled"                   # to populate timer variables
```

Without `sendPresentationCurrentMsgs: "disabled"`, the module repeatedly drops the connection on Pro7. See [troubleshooting](troubleshooting.md#propresenter-drops-connection).

### Verified action IDs

| Action ID | Description | Options |
|-----------|-------------|---------|
| `next` | Advance to next slide | (none) |
| `last` | Previous slide | (none) — note "last" not "prev" |
| `slideNumber` | Jump to specific slide | `slide` (1-based int as text), `path` (presentation path) |
| `clearall` | Clear every layer | (none) |
| `clearslide` | Clear slide layer only | (none) |
| `clearprops` | Clear props | (none) |
| `clearaudio` | Clear audio | (none) |
| `clearbackground` | Clear background | (none) |
| `cleartelestrator` | Clear telestrator | (none) |
| `cleartologo` | Clear to logo | (none) |
| `clearAnnouncements` | Clear announcements | (none) |
| `clearMessages` | Clear messages | (none) |
| `pro7SetLook` | Change Pro7 look | `pro7LookUUID` (dynamic — populated from PP instance) |
| `pro7TriggerMacro` | Trigger Pro7 macro | `pro7MacroUUID` (dynamic) |
| `pro7StageDisplayLayout` | Set Pro7 stage display layout | `pro7StageScreenUUID`, `pro7StageLayoutUUID` |
| `clockStart` | Start clock/timer | `clockIndex` (string, "0" for first) |
| `clockStop` | Stop clock | `clockIndex` |
| `clockReset` | Reset clock | `clockIndex` |
| `clockUpdate` | Set clock time | `clockName`, `clockIndex`, `clockTime` (string) |
| `messageSend` | Show message | `messageIndex`, `messageKeys`, `messageValues` |
| `messageHide` | Hide message | `messageIndex` |
| `audioPlayPause` | Toggle audio playback | (none) |
| `audioStartCue` | Start audio cue | `audioChildPath` |
| `timelinePlayPause` | Toggle timeline | `presentationPath` |
| `timelineRewind` | Rewind timeline | `presentationPath` |

### Action IDs that DO NOT exist (used incorrectly on page 42)

| Bad ID (page 42) | Correct ID |
|------------------|------------|
| `prev_slide` | `last` |
| `next_slide` | `next` |
| `trigger_next` | `next` |
| `trigger_slide` | `slideNumber` |
| `trigger_look` | `pro7SetLook` (with UUID, not name) |
| `clear_slide` | `clearslide` |
| `clear_media` | `clearbackground` (or `clearaudio`) |
| `clear_all` | `clearall` |
| `timer_start` / `timer_stop` / `timer_reset` | `clockStart` / `clockStop` / `clockReset` |
| `timer_adjust` | (no equivalent — use `clockUpdate`) |
| `toggle_message` | (no toggle — use `messageSend` / `messageHide`) |

See [page 42 doc](../pages/saitama-xl-42-prop.md) for the rewrite plan.

### Pro7 UUID gotcha

`pro7SetLook` and similar actions take **UUIDs**, not names. UUIDs are populated dynamically from the live PP instance and exposed in the Companion UI as a dropdown. They are not portable across PP instances — YIBC and Saitama have different UUIDs for the same look name. Hard-coding requires extracting UUIDs after first connect.

### Variables exposed (see [variables.md](variables.md))

Includes `current_slide`, `total_slides`, `presentation_name`, `video_countdown_timer`, `current_pro7_look_name`, etc.

---

## `obs` (TBD) actions in use

Connection not yet defined. Actions referenced in pages:

| Action ID | Used by |
|-----------|---------|
| `obs:toggle_streaming` | 30, 40, 43 |
| `obs:toggle_recording` | 30, 40, 43 |
| `obs:set_current_scene {scene: <Name>}` | 30, 40, 43 |

Feedbacks: `obs:streaming`, `obs:recording`, `obs:scene_active`, `obs:connected`. Verify all against the module after connection is added.

---

## `atem` (TBD) actions in use

| Action ID | Used by |
|-----------|---------|
| `atem:auto_transition` | 43 |
| `atem:cut_transition` | 43 |
| `atem:toggle_ftb` | 43 |

Feedbacks: `atem:connected`, `atem:ftb_active`. Verify against `bmd-atem` module.

---

## `homeassistant-server` actions

Connection defined but no buttons currently reference it. Reserved for future automation buttons (e.g. lights on/off, sanctuary HVAC).

---

## Cross-references

- Raw module dumps: [docs/companion/integrations/module-action-reference.md](../integrations/module-action-reference.md)
- Per-page mappings: [docs/companion/pages/](../pages/README.md)
- Connection definitions: [reference/connection-ids.md](connection-ids.md)
- Variables: [reference/variables.md](variables.md)
