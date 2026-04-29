# Variables Reference

Every variable available in YAML actions and button text, including custom variables defined in `variables.yaml` and dynamic variables exposed by connected modules.

## Reference syntax

In YAML, variables are referenced as `$(<connection_label>:<variable_id>)`.

The **label** in the reference is the connection's label with **non-alphanumeric characters sanitized to underscores**, NOT the connection `id` and NOT the raw label.

### Example

Connection in `connections.yaml`:

```yaml
- id: yamaha_yibc
  label: "Yamaha TF5 (YIBC)"
```

Companion sanitizes the label `Yamaha TF5 (YIBC)` → `Yamaha_TF5__YIBC_` (spaces become `_`, `(` and `)` become `_`, sequential underscores collapse depending on Companion version — verify in the UI).

Therefore the variable reference is:

```
$(Yamaha_TF5__YIBC_:modelName)    NOT $(yamaha_yibc:modelName)
                                  NOT $(Yamaha TF5 (YIBC):modelName)
```

For `internal` and the `internal:custom_*` namespace, use `internal` literally:

```
$(internal:time_hms)
$(internal:custom_ptz_speed)
$(internal:custom_service_mode)
```

For module-exposed variables, sanitize the connection label.

---

## Custom variables (defined in variables.yaml)

All custom variables live in the `internal:custom_*` namespace. Reference as `$(internal:custom_<name>)`.

| Name | Default | Persist | Purpose |
|------|---------|---------|---------|
| `startup_phase` | `Idle` | no | Service startup state machine driver |
| `service_mode` | `Off` | yes | Top-level service state: Off / Ready / Starting / Pre-Service / Live / Closing |
| `all_connected` | `"false"` | no | Reserved for connection-health aggregator |
| `pre_duck_level` | `"0"` | no | Stores stereo master level before duck so unducking can restore exactly |
| `duck_active` | `"0"` | no | Tracker for current duck state (0=normal, 1=ducked) |
| `ptz_speed` | `"12"` | no | PTZ pan/tilt speed mirror (1-24, VISCA scale) |
| `preset_sel_0` | `"0"` | no | D-Pad encoder E0 selected preset index |
| `preset_sel_1` | `"1"` | no | D-Pad encoder E1 selected preset index |
| `preset_name_0` | `Cross` | no | Computed name for preset_sel_0 |
| `preset_name_1` | `Wide` | no | Computed name for preset_sel_1 |

`persist: true` means the value survives Companion restart. Only `service_mode` persists by design; everything else resets on restart.

---

## Internal built-in variables

Provided by Companion core, no connection needed.

| Variable | Description | Example |
|----------|-------------|---------|
| `internal:time_hms` | Current time HH:MM:SS | `14:32:07` |
| `internal:time_h` | Hour | `14` |
| `internal:time_m` | Minute | `32` |
| `internal:time_s` | Second | `07` |
| `internal:date_iso` | ISO date | `2026-04-29` |
| `internal:uptime` | Companion uptime | `01:23:45` |
| `internal:custom_<name>` | Custom variables (see above) | `$(internal:custom_ptz_speed)` |

---

## ProPresenter variables

Connection labels: `ProPresenter_(YIBC)` (sanitized) for `propresenter_yibc`, `ProPresenter_(Saitama)` for `propresenter_saitama`. Verify exact sanitization in Companion UI.

| Variable ID | Description |
|-------------|-------------|
| `connection_status` | Connection state |
| `connection_timer` | Time since connect |
| `current_slide` | Current slide number |
| `total_slides` | Total slides in current presentation |
| `remaining_slides` | Slides remaining |
| `presentation_name` | Current presentation name |
| `current_presentation_path` | Current presentation file path |
| `current_announcement_presentation_path` | Announcement presentation path |
| `current_announcement_slide` | Announcement slide number |
| `current_stage_display_index` | Active stage display index |
| `current_stage_display_name` | Active stage display name |
| `current_pro7_look_name` | Active Pro7 Look name |
| `current_pro7_stage_layout_name` | Active stage layout name |
| `current_random_number` | Random number (from `newRandomNumber`) |
| `video_countdown_timer` | Video countdown timer (HH:MM:SS) |
| `video_countdown_timer_hourless` | Video countdown (MM:SS) |
| `video_countdown_timer_totalseconds` | Video countdown in seconds |
| `watched_clock_current_time` | Watched clock time |
| `time_since_last_clock_update` | Seconds since last clock change |
| `sd_connection_status` | Stage Display connection status |
| `pro7_clock_<N>` | Pro7 clock N (dynamic per clock; one variable per clock index) |

Trigger conditions reference these as `ProPresenter:video_countdown_timer` (the trigger's `internal:variable_value` event takes the connection label without sanitization in some Companion versions — verify against your version).

---

## Yamaha (yamaha-rcp) variables

Connection labels: `Yamaha_TF5__YIBC_` for `yamaha_yibc`, `Yamaha_TF1__Saitama_` for `yamaha_saitama`.

| Variable ID | Description |
|-------------|-------------|
| `modelName` | Mixer model name (e.g. `TF5`) |
| `deviceName` | User-set device label |
| `runMode` | Runtime mode |
| `error` | Last error / status |
| `curScene` | Current scene number |
| `curSceneName` | Current scene name |
| `curSceneComment` | Current scene comment |
| `cuedInChannels` | Cued input channels list |
| `cuedStInChannels` | Cued stereo input channels list |
| `cuedMixes` | Cued mix buses list |
| `cuedMatrices` | Cued matrices list |
| `cuedDCAs` | Cued DCAs list |

In addition, every bool feedback action with auto-create-variable enabled (e.g. `MIXER_Current/InCh/Fader/On X=11`) generates a derived variable. These are dynamically named and visible in the Companion UI under the connection's variables list.

---

## PTZ (ptzoptics-visca) variables

The module exposes minimal variables; most state is mirrored client-side via `custom_ptz_speed`. Verify dynamic variables in the Companion UI.

---

## OBS / ATEM variables (TBD)

Connections not yet defined. After adding, expect:

- `obs:current_scene`, `obs:streaming` (bool), `obs:recording` (bool), `obs:fps`, `obs:cpu_usage`, `obs:bytes_per_sec`, etc.
- `atem:program_input`, `atem:preview_input`, `atem:tally_<n>`, etc.

---

## Variable usage examples

### In button text

```yaml
style:
  text: "SPD $(internal:custom_ptz_speed)"
```

### In feedback (none currently — feedbacks compare to literal values, but can use variable expansion in text style)

### In action options (with expressions)

```yaml
- action: internal:custom_variable_set_expression
  options:
    name: "ptz_speed"
    expression: "min($(internal:custom_ptz_speed) + 1, 24)"
```

### In conditionals

```yaml
expression: >-
  $(internal:custom_preset_sel_0) == 0 ? 'Cross'
  : $(internal:custom_preset_sel_0) == 1 ? 'Wide'
  : 'Other'
```

---

## Cross-references

- Source YAML: `apps/companion/config/variables.yaml`
- Trigger conditions reference variables: [triggers.md](triggers.md)
- Module variables raw dump: [docs/companion/integrations/module-action-reference.md](../integrations/module-action-reference.md)
