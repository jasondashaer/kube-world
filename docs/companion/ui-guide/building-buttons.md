# Building Buttons in Companion

## Button Anatomy

Every button has four layers:

### 1. Style (Visual)
- **Text** — up to 3 lines, supports `$()` variables
- **Font size** — auto or fixed (7px to 44px)
- **Alignment** — left/center/right, top/middle/bottom
- **Color** — text color (hex)
- **Background** — background color (hex)
- **PNG image** — 72x72 pixels, optional overlay

### 2. Actions (Behavior)
Actions execute on button events. Each action specifies:
- **Instance** — which connection (e.g., "OBS Studio")
- **Action** — what to do (e.g., "Set Current Scene")
- **Options** — parameters (e.g., scene name)

**Action types by event:**
| Event | When |
|-------|------|
| Press | Button pressed down |
| Release | Button released |
| Long Press | Held for configured duration |
| Double Press | Tapped twice quickly |

**Multiple actions per event:** Actions fire sequentially, top to bottom. Add delays between actions with the built-in "Wait" action.

### 3. Feedbacks (State)
Feedbacks change appearance based on device state:
- **Boolean feedback** — condition met/not met → change style
- **Advanced feedback** — maps a value range to a style property

**Feedback layering:** Multiple feedbacks on one button. Evaluated top to bottom. Later feedbacks override earlier ones when their condition is true.

Example — camera button with program AND preview tally:
1. Default: gray
2. Feedback 1: Preview tally → green (lower priority)
3. Feedback 2: Program tally → red (higher priority, overrides green)

### 4. Steps (Multi-state)
Steps make a button cycle through different action sets:
- Step 1: Press → start recording
- Step 2: Press → stop recording

The button advances to the next step after executing. Feedbacks can show which step is active.

## Building a Button (Web UI)

1. Go to **Buttons** tab
2. Click a grid cell on the desired page
3. **Edit Style:** Set text, colors, font size
4. **Add Action:** Click "+" under Press/Release, select connection and action
5. **Add Feedback:** Click "+" under Feedbacks, select connection and feedback type, set condition
6. **Test:** Press the physical button on Stream Deck or click in the web UI

## Building a Button (YAML)

```yaml
buttons:
  - row: 0
    col: 0
    type: button
    style:
      text: "Line 1\nLine 2"
      size: 18
      color: "#FFFFFF"
      bgcolor: "#0066CC"
      alignment: "center:center"
    actions:
      down:
        - action: obs:set_current_scene
          options:
            scene: "Camera 1"
      up: []
    feedbacks:
      - type: obs:scene_active
        options:
          scene: "Camera 1"
        style:
          bgcolor: "#00CC00"
```

## Common Button Patterns

### Navigation Button
```yaml
- text: "← BACK\n戻る"
  bgcolor: "#0066CC"
  actions:
    down:
      - action: companion:page_set
        options:
          page: 1
```

### Toggle with State
```yaml
- text: "Mute\nミュート"
  bgcolor: "#00CC00"
  actions:
    down:
      - action: yamaha:channel_mute_toggle
        options: { channel: 1 }
  feedbacks:
    - type: yamaha:channel_muted
      options: { channel: 1 }
      style:
        bgcolor: "#CC0000"
        text: "MUTED\nミュート中"
```

### Confirmation Button (Two-step)
```yaml
# Dangerous action — requires two presses
steps:
  - text: "SHUTDOWN\nシャットダウン"
    bgcolor: "#CC0000"
    actions:
      down:
        - action: companion:step_next  # Just advances to step 2
  - text: "CONFIRM?\n確認？"
    bgcolor: "#FF0000"
    actions:
      down:
        - action: ssh:send_command
          options: { command: "sudo shutdown -h now" }
        - action: companion:step_reset  # Back to step 1
```

### Status Display (No action)
```yaml
- text: "$(obs:streaming_status)"
  bgcolor: "#333333"
  actions: {}
  feedbacks:
    - type: obs:streaming
      style:
        bgcolor: "#CC0000"
        text: "● LIVE"
```
