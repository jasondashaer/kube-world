# Building Buttons in Companion

## Button Anatomy

Every button has four layers: **Style** (visual), **Actions** (behavior), **Feedbacks** (state), and **Steps** (multi-state). Understanding how these interact is critical for building buttons that are both functional and informative.

---

## 1. Style (Visual Layer)

The base appearance when no feedbacks are active.

| Property | Values | Notes |
|----------|--------|-------|
| Text | Up to 3 lines, `\n` for line breaks | Supports `$(connection:variable)` for dynamic text |
| Font size | `auto`, or 7px to 44px | `auto` scales to fit; fixed for consistent layouts |
| Text color | Hex `#RRGGBB` | Default: white |
| Background color | Hex `#RRGGBB` | Default: black |
| Alignment | `left:top`, `center:center`, `right:bottom`, etc. | Horizontal:Vertical |
| PNG image | 72x72 pixels | Overlays on top of background color, under text |
| Show topbar | true/false | Thin colored bar at top of button (page indicator) |

**Dynamic text with variables:**
```yaml
text: "$(obs:scene_name)\n$(obs:fps) FPS"
# Shows: "Camera 1\n30 FPS" — updates in real-time
```

---

## 2. Actions (Behavior Layer)

Actions define what happens when the button is physically interacted with. Companion supports multiple action events per button.

### Action Events

| Event | Trigger | Use Case |
|-------|---------|----------|
| **Press (down)** | Finger touches button | Primary action — most buttons use this |
| **Release (up)** | Finger lifts off button | "Push-to-talk" mute, momentary holds |
| **Long Press** | Held for configured duration (default 500ms) | Secondary/alternate action |
| **Double Press** | Two quick taps within 400ms | Shortcut action, "confirm by double-tap" |
| **Rotate CW** | Clockwise turn (Stream Deck+ only) | Volume up, fader increase |
| **Rotate CCW** | Counter-clockwise turn | Volume down, fader decrease |

### Action Execution

Actions within a single event fire **sequentially, top to bottom**. Use the built-in **Wait/Delay** action to insert timing between actions.

```yaml
actions:
  down:
    - action: atem:set_preview_input     # 1. Set preview
      options: { input: 1 }
    - action: companion:wait             # 2. Wait 500ms
      options: { time: 500 }
    - action: atem:auto_transition       # 3. Execute transition
```

### Single Click (Press Only)

The most common pattern. Action fires on press, nothing on release.

```yaml
# Simple scene switch
actions:
  down:
    - action: obs:set_current_scene
      options:
        scene: "Camera 1"
```

### Press and Release (Momentary)

Action on press, opposite action on release. Button only "active" while held.

```yaml
# Push-to-talk: unmute while held, mute on release
actions:
  down:
    - action: yamaha:channel_mute_set
      options:
        channel: 1
        mute: false    # Unmute on press
  up:
    - action: yamaha:channel_mute_set
      options:
        channel: 1
        mute: true     # Re-mute on release
```

```yaml
# Hold to show camera preview, release to cut back
actions:
  down:
    - action: atem:set_preview_input
      options: { input: 2 }
    - action: atem:auto_transition
  up:
    - action: atem:set_preview_input
      options: { input: 1 }
    - action: atem:auto_transition
```

### Long Press (Hold for Alternate Action)

Different action when button is held vs tapped. Configure hold duration in button settings (default 500ms).

```yaml
# Tap = preview camera, Hold = cut to camera immediately
actions:
  down:
    - action: atem:set_preview_input
      options: { input: 3 }
  long_press:
    - action: atem:set_program_input    # Dangerous: goes live immediately
      options: { input: 3 }
```

```yaml
# Tap = mute toggle, Hold = solo channel (monitor only this channel)
actions:
  down:
    - action: yamaha:channel_mute_toggle
      options: { channel: 5 }
  long_press:
    - action: yamaha:channel_solo
      options: { channel: 5 }
```

### Double Press (Quick Confirm)

Two taps within 400ms. Use for actions that need quick confirmation without the visual overhead of a two-step button.

```yaml
# Single tap = no action (prevents accidental), Double tap = execute
actions:
  down: []                              # Single tap does nothing
  double_press:
    - action: obs:toggle_streaming      # Double tap toggles stream
```

### Multi-Action Chains with Delays

Complex sequences that automate multi-step workflows.

```yaml
# "Start Service" button: powers on equipment in sequence
actions:
  down:
    - action: wol:wake                           # 1. Wake computer
      options: { mac: "AA:BB:CC:DD:EE:FF" }
    - action: companion:wait                     # 2. Wait 30s for boot
      options: { time: 30000 }
    - action: ssh:send_command                   # 3. Launch ProPresenter
      options: { command: "open -a ProPresenter" }
    - action: companion:wait                     # 4. Wait 10s for app
      options: { time: 10000 }
    - action: propresenter:trigger_playlist      # 5. Load today's playlist
      options: { playlist: "Sunday Service" }
    - action: yamaha:scene_recall                # 6. Recall mixer preset
      options: { scene: 1 }
    - action: atem:set_program_input             # 7. Set default camera
      options: { input: 1 }
```

---

## 3. Feedbacks (State Layer)

Feedbacks continuously poll connected devices and change button appearance based on conditions. They are the key to making buttons informative — volunteers should never wonder "what state is this in?"

### How Feedbacks Work

1. Companion polls the device on an interval (varies by module, usually 100ms-1s)
2. Each feedback evaluates its condition against the device state
3. If condition is TRUE, the feedback's style overrides the button's base style
4. If condition is FALSE, the feedback has no effect
5. Multiple feedbacks layer — later feedbacks override earlier ones

### Boolean Feedbacks (On/Off)

The simplest type. Condition is either met or not.

```yaml
# Green when connected, stays default (gray) when disconnected
feedbacks:
  - type: obs:connected
    style:
      bgcolor: "#00CC00"
```

```yaml
# Red when muted, green when unmuted
feedbacks:
  - type: yamaha:channel_muted
    options:
      channel: 1
    style:
      bgcolor: "#CC0000"
      text: "MUTED\nミュート中"
  # Note: when NOT muted, button shows default style (green + "Pastor")
```

### Connection Status Indicators

Show whether a device is reachable. Critical for startup sequences and troubleshooting.

```yaml
# Connection status button — shows state of each system
style:
  text: "OBS"
  bgcolor: "#CC0000"        # Default: red (not connected)
feedbacks:
  - type: obs:connected
    style:
      bgcolor: "#00CC00"    # Green when connected
      text: "OBS\n● Online"
```

```yaml
# Waiting-to-come-online pattern — yellow during connection attempt
style:
  text: "ATEM"
  bgcolor: "#CC0000"          # Red: disconnected
feedbacks:
  - type: atem:connecting     # Module-specific "connecting" state
    style:
      bgcolor: "#CCCC00"     # Yellow: trying to connect
      text: "ATEM\n⟳ Wait"
  - type: atem:connected      # Higher priority (listed after)
    style:
      bgcolor: "#00CC00"     # Green: connected
      text: "ATEM\n● Online"
```

### Multi-State Feedback Layering

When multiple feedbacks are true simultaneously, later ones override earlier ones. Use this for priority-based visual states.

```yaml
# Camera button with 4 possible states:
style:
  text: "CAM 1\nカメラ1"
  bgcolor: "#666666"            # Default: gray (inactive)

feedbacks:
  # State 1: Connected (low priority — just means reachable)
  - type: atem:connected
    style:
      bgcolor: "#333333"       # Dark gray: connected but not selected

  # State 2: Preview (medium priority)
  - type: atem:preview_tally
    options: { input: 1 }
    style:
      bgcolor: "#00CC00"       # Green: on preview

  # State 3: Program/Live (highest priority — overrides preview)
  - type: atem:program_tally
    options: { input: 1 }
    style:
      bgcolor: "#CC0000"       # Red: LIVE on program
      text: "● LIVE\nカメラ1"
```

### Variable-Driven Display

Use `$()` variables in feedback text to show real-time values.

```yaml
# Fader level display
style:
  text: "Master\n$(yamaha:stereo_level) dB"
  bgcolor: "#333333"
feedbacks:
  - type: yamaha:channel_muted
    options: { channel: "stereo" }
    style:
      bgcolor: "#CC0000"
      text: "MUTED\n$(yamaha:stereo_level) dB"
```

```yaml
# Stream status with uptime
style:
  text: "Stream\n配信"
  bgcolor: "#666666"
feedbacks:
  - type: obs:streaming
    style:
      bgcolor: "#CC0000"
      text: "● LIVE\n$(obs:stream_timecode)"
      # Shows: "● LIVE\n01:23:45"
```

```yaml
# Timer display
style:
  text: "Timer\nタイマー"
  bgcolor: "#333333"
feedbacks:
  - type: companion:timer_running
    options: { timer: "sermon_timer" }
    style:
      text: "$(companion:timer_sermon_timer_remaining)"
      bgcolor: "#00CC00"
  - type: companion:timer_under
    options: { timer: "sermon_timer", threshold: 60 }
    style:
      bgcolor: "#CCCC00"     # Yellow: under 1 minute
  - type: companion:timer_expired
    options: { timer: "sermon_timer" }
    style:
      bgcolor: "#CC0000"     # Red: time's up
      text: "TIME!\n時間超過"
```

---

## 4. Steps (Multi-State Layer)

Steps make a button cycle through different configurations on each press. The button's style, actions, AND feedbacks can differ per step.

### Two-Step Toggle

```yaml
# Record toggle: press to start, press again to stop
steps:
  - # Step 1: Ready to record
    style:
      text: "REC\n録画"
      bgcolor: "#666666"
    actions:
      down:
        - action: obs:start_recording
    feedbacks: []

  - # Step 2: Currently recording
    style:
      text: "■ STOP\n停止"
      bgcolor: "#CC0000"
    actions:
      down:
        - action: obs:stop_recording
    feedbacks:
      - type: obs:recording
        style:
          text: "● REC\n$(obs:record_timecode)"
```

### Safety Confirmation

```yaml
# Dangerous action with confirmation step and auto-revert
steps:
  - # Step 1: Normal state
    style:
      text: "Kill Stream\n配信停止"
      bgcolor: "#CC0000"
    actions:
      down:
        - action: companion:step_next
        # Auto-revert after 5 seconds if not confirmed:
        - action: companion:wait
          options: { time: 5000 }
        - action: companion:step_set
          options: { step: 1 }

  - # Step 2: Confirmation (flashing/bright)
    style:
      text: "CONFIRM?\n確認？"
      bgcolor: "#FF0000"
      color: "#FFFFFF"
    actions:
      down:
        - action: obs:stop_streaming
        - action: companion:step_set
          options: { step: 1 }  # Reset after execution
```

### Three-Step Sequence

```yaml
# Transition workflow: 1) select, 2) preview, 3) execute
steps:
  - # Step 1: Select source
    style: { text: "Select\n選択", bgcolor: "#0066CC" }
    actions:
      down:
        - action: atem:set_preview_input
          options: { input: 2 }

  - # Step 2: Preview confirmed, ready to cut
    style: { text: "Ready\n準備", bgcolor: "#CCCC00" }
    actions:
      down:
        - action: atem:auto_transition

  - # Step 3: Done, back to start
    style: { text: "Done ✓\n完了", bgcolor: "#00CC00" }
    actions:
      down:
        - action: companion:step_set
          options: { step: 1 }
```

---

## 5. Advanced Patterns

### Startup Sequence with Progress

Show boot-up progress across multiple status buttons:

```yaml
# Button shows current startup phase
style:
  text: "Starting...\n起動中"
  bgcolor: "#CCCC00"
actions:
  down:
    - action: wol:wake
      options: { mac: "AA:BB:CC:DD:EE:FF" }
    - action: companion:variable_set
      options: { variable: "startup_phase", value: "Booting" }
    - action: companion:wait
      options: { time: 30000 }
    - action: companion:variable_set
      options: { variable: "startup_phase", value: "Launching apps" }
    - action: companion:wait
      options: { time: 15000 }
    - action: companion:variable_set
      options: { variable: "startup_phase", value: "Ready" }
feedbacks:
  - type: companion:variable_value
    options:
      variable: "startup_phase"
      value: "Ready"
    style:
      bgcolor: "#00CC00"
      text: "Ready ✓\n準備完了"
```

### Connection Dashboard Row

A row of buttons showing all system connection states:

```yaml
# Position [0,0] through [0,5] — top row, one per system
buttons:
  - row: 0
    col: 0
    style: { text: "PP", bgcolor: "#CC0000" }
    feedbacks:
      - type: propresenter:connected
        style: { bgcolor: "#00CC00", text: "PP\n● OK" }

  - row: 0
    col: 1
    style: { text: "OBS", bgcolor: "#CC0000" }
    feedbacks:
      - type: obs:connected
        style: { bgcolor: "#00CC00", text: "OBS\n● OK" }

  - row: 0
    col: 2
    style: { text: "ATEM", bgcolor: "#CC0000" }
    feedbacks:
      - type: atem:connected
        style: { bgcolor: "#00CC00", text: "ATEM\n● OK" }

  - row: 0
    col: 3
    style: { text: "Audio", bgcolor: "#CC0000" }
    feedbacks:
      - type: yamaha:connected
        style: { bgcolor: "#00CC00", text: "Audio\n● OK" }

  - row: 0
    col: 4
    style: { text: "HA", bgcolor: "#CC0000" }
    feedbacks:
      - type: homeassistant:connected
        style: { bgcolor: "#00CC00", text: "HA\n● OK" }

  - row: 0
    col: 5
    style: { text: "ALL", bgcolor: "#CC0000" }
    feedbacks:
      # Only green when ALL systems connected
      - type: propresenter:connected
        style: {}   # No visual change alone
      # Use a trigger + variable to aggregate:
      # Set custom variable "all_connected" via trigger logic
      - type: companion:variable_value
        options: { variable: "all_connected", value: "true" }
        style: { bgcolor: "#00CC00", text: "ALL ✓\n全接続" }
```

### Conditional Button Visibility

Buttons that only show content when relevant:

```yaml
# Empty/hidden when no active presentation, shows slide info when loaded
style:
  text: ""
  bgcolor: "#000000"   # Black = invisible on Stream Deck
feedbacks:
  - type: propresenter:active_presentation
    style:
      bgcolor: "#333333"
      text: "$(propresenter:current_slide_index)/$(propresenter:total_slides)"
```

### Fader/Level Control (Stream Deck+ Encoders)

For devices with rotary encoders:

```yaml
# Rotary encoder for volume control
style:
  text: "Master\n$(yamaha:stereo_level) dB"
  bgcolor: "#333333"
actions:
  rotate_cw:
    - action: yamaha:channel_fader_step
      options: { channel: "stereo", step: 1 }    # +1 dB
  rotate_ccw:
    - action: yamaha:channel_fader_step
      options: { channel: "stereo", step: -1 }   # -1 dB
  down:
    - action: yamaha:channel_mute_toggle           # Press = mute toggle
      options: { channel: "stereo" }
```

---

## YAML-to-Config Reference

The `churchSupport` repo converter (`scripts/yaml-to-companion.py`) generates `.companionconfig` JSON from YAML specs. Full YAML schema:

```yaml
page:
  number: 1                    # Companion page number
  name: "Page Name"
  name_jp: "ページ名"

buttons:
  - row: 0                     # 0-3 for Stream Deck XL
    col: 0                     # 0-7 for Stream Deck XL
    type: button               # "button" or "pageup"/"pagedown"
    style:
      text: "Label\n日本語"
      size: 18                 # Font size (auto if omitted)
      color: "#FFFFFF"         # Text color
      bgcolor: "#0066CC"       # Background color
      alignment: "center:center"
      png64: ""                # Base64 encoded PNG (72x72)
      show_topbar: false
    actions:
      down: [...]              # Press actions
      up: [...]                # Release actions
      long_press: [...]        # Hold actions (500ms default)
      double_press: [...]      # Double-tap actions
      rotate_cw: [...]         # Clockwise rotation (encoders)
      rotate_ccw: [...]        # Counter-clockwise rotation
    feedbacks:
      - type: "connection:feedback_id"
        options: { key: value }
        style:                 # Style override when feedback is true
          text: "Override"
          bgcolor: "#CC0000"
          color: "#FFFFFF"
    steps:                     # Optional: multi-step button
      - style: {...}
        actions: {...}
        feedbacks: [...]
      - style: {...}
        actions: {...}
        feedbacks: [...]
```
