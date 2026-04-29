# PTZ Camera Integration

## Important: Action ID Reference

The `ptzoptics-visca` module (v3.5.0) uses these **actual action IDs** (definitionIds). Documentation examples below use descriptive names for clarity but YAML configs must use these exact IDs:

| Action | definitionId | Options |
|--------|-------------|---------|
| Pan Left | `left` | none |
| Pan Right | `right` | none |
| Tilt Up | `up` | none |
| Tilt Down | `down` | none |
| Stop Movement | `stop` | none |
| Home Position | `home` | none |
| Zoom In | `zoomI` | none |
| Zoom Out | `zoomO` | none |
| Zoom Stop | `zoomS` | none |
| Focus Near | `focusN` | none |
| Focus Far | `focusF` | none |
| Focus Stop | `focusS` | none |
| Focus Mode Toggle | `focusM` | none |
| Recall Preset | `recallPreset` | `{isText: false, presetAsNumber: N}` |
| Save Preset | `setPreset` | `{isText: false, presetAsNumber: N}` |
| Set P/T Speed | `ptSpeedSet` | `{speed: 1-24}` |
| Speed Up | `ptSpeedU` | none |
| Speed Down | `ptSpeedD` | none |
| Power | `power` | state |
| Custom Command | `custom` | `{custom: "81 01 ..."}` |

Internal Companion action IDs used alongside PTZ:

| Action | definitionId | Options |
|--------|-------------|---------|
| Set Variable | `custom_variable_set_value` | `{name: "var", value: "val"}` |
| Set via Expression | `custom_variable_set_expression` | `{name: "var", expression: "..."}` |
| Set Page | `set_page` | `{controller: "self", page: N}` |
| Wait/Delay | `wait` | `{time: "ms_expression"}` |
| Step Advance | `step_delta` | `{amount: 1}` |

## Overview

PTZ (Pan-Tilt-Zoom) cameras are controlled via network protocols — most commonly VISCA over TCP/IP. Companion has modules for most major PTZ brands, all sharing similar action patterns.

## Companion Modules by Brand

| Brand | Module | Protocol | Notes |
|-------|--------|----------|-------|
| PTZOptics | `ptzoptics-visca` | VISCA/TCP | Most common church/streaming PTZ |
| Panasonic | `panasonic-ptz` | HTTP commands | AW-HE/UE series |
| Sony | `sony-visca` | VISCA/TCP | SRG/BRC series |
| OBSBOT | `obsbot-rest` | REST API | AI tracking cameras |
| Birddog | `birddog-ptz` | VISCA/NDI | NDI-native PTZ |
| Marshall | `marshall-cv-ptz` | VISCA | Budget PTZ |
| HuddleCam | `ptzoptics-visca` | VISCA | Uses PTZOptics module (same protocol) |
| Any VISCA | `generic-visca` | VISCA/TCP or Serial | Fallback for unknown brands |
| Via ATEM | `bmd-atem` | ATEM protocol | Camera control through ATEM switcher |

**If unsure which module:** Start with `ptzoptics-visca` — it's the most compatible VISCA implementation and works with many non-PTZOptics cameras too.

## Connection

| Setting | Value |
|---------|-------|
| Host | Camera IP address |
| Port | 5678 (VISCA default), varies by brand |
| Protocol | TCP (most), UDP (some), HTTP (Panasonic) |

**Setup:** Camera must be on the same network. Assign a static IP to the camera (most PTZ cameras default to DHCP). Find the IP via the camera's OSD menu or brand-specific discovery tool.

## Common VISCA Actions

These actions are available in most VISCA-based modules. Exact names vary slightly per module.

### Pan/Tilt Movement

| Action | Description | Options |
|--------|-------------|---------|
| **Pan Left** | Continuous pan left | speed (1-24) |
| **Pan Right** | Continuous pan right | speed (1-24) |
| **Tilt Up** | Continuous tilt up | speed (1-20) |
| **Tilt Down** | Continuous tilt down | speed (1-20) |
| **Pan/Tilt Stop** | Stop all movement | — |
| **Pan/Tilt Home** | Return to home position | — |
| **Pan/Tilt Absolute** | Move to specific coordinates | pan_pos, tilt_pos, speed |
| **Pan/Tilt Relative** | Move by offset from current | pan_offset, tilt_offset, speed |

**Speed range:** 1 (slowest) to 24 (fastest) for pan, 1-20 for tilt. Most cameras have internal acceleration/deceleration curves.

### Zoom

| Action | Description | Options |
|--------|-------------|---------|
| **Zoom In** | Continuous zoom tele | speed (0-7) |
| **Zoom Out** | Continuous zoom wide | speed (0-7) |
| **Zoom Stop** | Stop zoom movement | — |
| **Zoom Absolute** | Set specific zoom level | position (0-16384) |
| **Zoom Direct** | Jump to zoom position | position |

### Focus

| Action | Description | Options |
|--------|-------------|---------|
| **Focus Near** | Continuous focus near | speed (0-7) |
| **Focus Far** | Continuous focus far | speed (0-7) |
| **Focus Stop** | Stop focus movement | — |
| **Focus Auto** | Enable auto-focus | — |
| **Focus Manual** | Switch to manual focus | — |
| **Focus Auto Toggle** | Toggle auto/manual | — |
| **Focus One-Push** | Single auto-focus then return to manual | — |
| **Focus Absolute** | Set specific focus position | position |

### Presets (Memory)

| Action | Description | Options |
|--------|-------------|---------|
| **Preset Recall** | Move to saved position | preset (0-255) |
| **Preset Save** | Save current position | preset (0-255) |
| **Preset Clear** | Delete a saved position | preset |
| **Preset Speed** | Set recall movement speed | speed |

**Typical preset allocation:**
| Preset | Name | Use |
|--------|------|-----|
| 0 | Home / Wide | Default wide shot |
| 1 | Pulpit Close | Speaker close-up |
| 2 | Worship Leader | Music leader |
| 3 | Piano/Keys | Keyboard player |
| 4 | Choir Wide | Full choir shot |
| 5 | Baptistry | Baptism area |
| 6-9 | Custom | Service-specific |

### Exposure / White Balance

| Action | Description | Options |
|--------|-------------|---------|
| **Exposure Mode** | Auto/manual/shutter/iris priority | mode |
| **Iris Up/Down** | Adjust aperture | — |
| **Iris Direct** | Set specific iris value | value |
| **Shutter Up/Down** | Adjust shutter speed | — |
| **Gain Up/Down** | Adjust sensor gain/ISO | — |
| **Backlight Comp** | Toggle backlight compensation | on/off |
| **White Balance Mode** | Auto/manual/preset | mode |
| **WB One-Push** | Single auto WB then hold | — |
| **WB Red/Blue Gain** | Manual WB adjustment | value |

### Power / System

| Action | Description |
|--------|-------------|
| **Power On** | Wake camera from standby |
| **Power Off** | Put camera in standby |
| **Tally On/Off** | Enable/disable tally light |
| **OSD Menu** | Open/close on-screen display |
| **Info Display** | Show camera info overlay |

## Common Feedbacks

| Feedback | Description |
|----------|-------------|
| **Power State** | Camera on/standby |
| **Zoom Position** | Current zoom level |
| **Focus Mode** | Auto/manual |
| **Preset Active** | Which preset is currently recalled |
| **Tally State** | Tally light on/off |
| **Connection Status** | Connected/disconnected |

## Common Variables

| Variable | Description |
|----------|-------------|
| `$(ptz:pan_position)` | Current pan position |
| `$(ptz:tilt_position)` | Current tilt position |
| `$(ptz:zoom_position)` | Current zoom level (0-16384) |
| `$(ptz:zoom_pct)` | Zoom as percentage (0-100%) |
| `$(ptz:focus_mode)` | Auto/manual |
| `$(ptz:focus_position)` | Current focus position |
| `$(ptz:preset_last)` | Last recalled preset number |
| `$(ptz:power)` | Power state (on/standby) |
| `$(ptz:model)` | Camera model string |

*Note: Variable prefix depends on the module (e.g., `$(ptzoptics:...)`, `$(panasonic:...)`).*

## Button Patterns

### Preset Recall Grid (Buttons)

```yaml
# Preset buttons — one per saved position
- row: 0
  col: 0
  style:
    text: "Wide\nワイド"
    bgcolor: "#0066CC"
  actions:
    down:
      - action: ptz:preset_recall
        options: { preset: 0 }
    long_press:
      - action: ptz:preset_save
        options: { preset: 0 }
  feedbacks:
    - type: ptz:preset_active
      options: { preset: 0 }
      style:
        bgcolor: "#00CC00"
        text: "● Wide"

- row: 0
  col: 1
  style:
    text: "Close\nアップ"
    bgcolor: "#0066CC"
  actions:
    down:
      - action: ptz:preset_recall
        options: { preset: 1 }
    long_press:
      - action: ptz:preset_save
        options: { preset: 1 }
  feedbacks:
    - type: ptz:preset_active
      options: { preset: 1 }
      style:
        bgcolor: "#00CC00"
```

### PTZ Encoder Control (Stream Deck+)

```yaml
encoders:
  # E0: Pan
  - encoder: 0
    style:
      text: "PAN"
      size: 14
    actions:
      rotate_cw:
        - action: ptz:pan_right
          options: { speed: 8 }
      rotate_ccw:
        - action: ptz:pan_left
          options: { speed: 8 }
      down:
        - action: ptz:pan_tilt_home
      long_press:
        - action: ptz:pan_tilt_stop

  # E1: Tilt
  - encoder: 1
    style:
      text: "TILT"
    actions:
      rotate_cw:
        - action: ptz:tilt_up
          options: { speed: 6 }
      rotate_ccw:
        - action: ptz:tilt_down
          options: { speed: 6 }
      down:
        - action: ptz:pan_tilt_home
      long_press:
        - action: ptz:pan_tilt_stop

  # E2: Zoom
  - encoder: 2
    style:
      text: "ZOOM\n$(ptz:zoom_pct)%"
    actions:
      rotate_cw:
        - action: ptz:zoom_in
          options: { speed: 3 }
      rotate_ccw:
        - action: ptz:zoom_out
          options: { speed: 3 }
      down:
        - action: ptz:preset_recall
          options: { preset: 0 }  # Wide shot
      long_press:
        - action: ptz:zoom_stop

  # E3: Focus
  - encoder: 3
    style:
      text: "FOCUS"
    actions:
      rotate_cw:
        - action: ptz:focus_far
          options: { speed: 2 }
      rotate_ccw:
        - action: ptz:focus_near
          options: { speed: 2 }
      down:
        - action: ptz:focus_auto_toggle
      long_press:
        - action: ptz:focus_one_push
    feedbacks:
      - type: ptz:focus_mode
        options: { mode: "auto" }
        style:
          bgcolor: "#00CC00"
          text: "AF"
      - type: ptz:focus_mode
        options: { mode: "manual" }
        style:
          bgcolor: "#CCCC00"
          text: "MF"
```

### Speed Selection Buttons + Encoder Movement

```yaml
# Speed select buttons (row 1)
- row: 1
  col: 0
  style:
    text: "Slow\nゆっくり"
    bgcolor: "#333333"
  actions:
    down:
      - action: internal:variable_set
        options: { variable: "ptz_speed", value: "3" }
  feedbacks:
    - type: internal:variable_value
      options: { variable: "ptz_speed", value: "3" }
      style:
        bgcolor: "#00CC00"

- row: 1
  col: 1
  style:
    text: "Med\n中速"
    bgcolor: "#333333"
  actions:
    down:
      - action: internal:variable_set
        options: { variable: "ptz_speed", value: "8" }
  feedbacks:
    - type: internal:variable_value
      options: { variable: "ptz_speed", value: "8" }
      style:
        bgcolor: "#00CC00"

- row: 1
  col: 2
  style:
    text: "Fast\n高速"
    bgcolor: "#333333"
  actions:
    down:
      - action: internal:variable_set
        options: { variable: "ptz_speed", value: "16" }
  feedbacks:
    - type: internal:variable_value
      options: { variable: "ptz_speed", value: "16" }
      style:
        bgcolor: "#00CC00"

# Encoders use the speed variable
encoders:
  - encoder: 0
    style:
      text: "PAN"
    actions:
      rotate_cw:
        - action: ptz:pan_right
          options: { speed: "$(internal:ptz_speed)" }
      rotate_ccw:
        - action: ptz:pan_left
          options: { speed: "$(internal:ptz_speed)" }
```

### D-Pad Style Pan/Tilt (Standard Stream Deck)

For Stream Decks without encoders, use a button grid as a virtual joystick:

```yaml
# 3x3 D-pad layout centered in the grid
#     [  UP  ]
# [LEFT][HOME][RIGHT]
#     [ DOWN ]

- row: 0
  col: 3
  style: { text: "▲\n上", bgcolor: "#333333" }
  actions:
    down:
      - action: ptz:tilt_up
        options: { speed: 8 }
    up:
      - action: ptz:pan_tilt_stop

- row: 2
  col: 3
  style: { text: "▼\n下", bgcolor: "#333333" }
  actions:
    down:
      - action: ptz:tilt_down
        options: { speed: 8 }
    up:
      - action: ptz:pan_tilt_stop

- row: 1
  col: 2
  style: { text: "◄\n左", bgcolor: "#333333" }
  actions:
    down:
      - action: ptz:pan_left
        options: { speed: 8 }
    up:
      - action: ptz:pan_tilt_stop

- row: 1
  col: 4
  style: { text: "►\n右", bgcolor: "#333333" }
  actions:
    down:
      - action: ptz:pan_right
        options: { speed: 8 }
    up:
      - action: ptz:pan_tilt_stop

- row: 1
  col: 3
  style: { text: "⌂\nHome", bgcolor: "#0066CC" }
  actions:
    down:
      - action: ptz:pan_tilt_home
```

**Key pattern:** `down` = start moving, `up` = stop. This gives **momentary movement** — camera moves only while button is held.

## Smooth Movement Tips

### Camera-Side Ramp Curves

Most PTZ cameras have configurable acceleration/deceleration in their OSD menus:

| Brand | Setting | Location |
|-------|---------|----------|
| PTZOptics | Speed by Preset | OSD > P/T/Z > Speed |
| Panasonic | Ramp Curve | Web UI > PTZ > Ramp |
| Sony | Pan Tilt Slow Mode | OSD > Pan Tilt > Slow |

**Set these on the camera itself** — Companion sends direction + speed, the camera handles the smoothing. This is more reliable than trying to simulate ramping via Companion variables.

### Recommended Speed Settings

| Situation | Pan Speed | Tilt Speed | Zoom Speed |
|-----------|-----------|------------|------------|
| Live on-air movement | 3-6 | 3-5 | 1-2 |
| Pre-show framing | 8-12 | 6-10 | 3-4 |
| Fast repositioning | 16-24 | 14-20 | 5-7 |

**Never use max speed during live broadcast** — fast moves are jarring on camera. Use presets for big position changes instead of manual pan/tilt.

### Preset Recall Speed

Most cameras support setting the **recall speed** separately from manual movement speed. Slow preset recalls (speed 5-8) look professional. Fast recalls (speed 15+) are for off-air repositioning.

```yaml
# Preset with slow recall (on-air quality)
- action: ptz:preset_speed
  options: { speed: 6 }
- action: ptz:preset_recall
  options: { preset: 1 }
```

## Troubleshooting

- **Camera doesn't respond** — verify IP, check if VISCA/HTTP control is enabled in camera settings, try pinging the camera
- **Movement is jerky** — reduce speed value, enable ramp curves in camera OSD
- **Presets don't save** — some cameras require "Preset Mode: Full" (saves zoom/focus/exposure with position)
- **Focus hunts** — switch to manual focus for fixed-position shots, use one-push AF then switch to manual
- **Tally doesn't work** — tally requires ATEM integration or separate tally protocol, not all VISCA modules support tally
- **Zoom overshoots** — reduce zoom speed to 1-2 for fine control, use absolute zoom positions instead of continuous
- **Multiple cameras** — create one connection per camera in Companion, use page-per-camera or color-coded buttons to distinguish
