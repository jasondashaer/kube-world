# Stream Deck+ Encoders — Complete Guide

## Hardware Overview

The Stream Deck+ has:
- **8 LCD buttons** (4 columns x 2 rows) — same as standard buttons
- **4 rotary encoders** (knobs) — below the buttons, with push-click
- **1 touch LCD strip** — horizontal strip between buttons and encoders, divided into 4 zones (one per encoder)

```
┌──────────────────────────────┐
│ [0,0] [0,1] [0,2] [0,3]     │  ← Row 0: LCD buttons
│ [1,0] [1,1] [1,2] [1,3]     │  ← Row 1: LCD buttons
├──────────────────────────────┤
│  LCD   LCD   LCD   LCD       │  ← Touch LCD strip (4 zones)
│  [E0]  [E1]  [E2]  [E3]     │  ← Encoders (rotary + push)
└──────────────────────────────┘
```

## Encoder Actions

Each encoder supports **5 action events** (vs 4 for buttons):

| Event | Trigger | Use Case |
|-------|---------|----------|
| **Press (down)** | Push the knob in | Toggle, select, confirm |
| **Release (up)** | Release the knob | End momentary action |
| **Rotate CW** | Turn clockwise | Increase value (volume, brightness, fader) |
| **Rotate CCW** | Turn counter-clockwise | Decrease value |
| **Long Press** | Hold knob pressed for 500ms+ | Reset to default, alternate action |

**NOT supported on encoders:**
- Double press (hardware doesn't distinguish)
- Touch/swipe on the encoder knob itself (only the LCD strip is touch-sensitive)
- Rotary acceleration (Companion receives fixed-step events regardless of turn speed)

## Encoder Feedback Display

Encoders have a small **LCD segment** directly above each knob (part of the touch strip). This displays:
- Text (1-2 lines, small font)
- Background color
- Simple indicators

**The LCD segment updates from feedbacks just like button displays.** But the rendering area is much smaller than a button — design accordingly.

### LCD Display Constraints

| Property | Button | Encoder LCD |
|----------|--------|-------------|
| Width | 72px | ~100px (wider but shorter) |
| Height | 72px | ~30px (very short) |
| Text lines | 3 comfortable | 1-2 max |
| Font size | 7-44px | 7-18px practical |
| Image | 72x72 PNG | Not well supported |
| Color | Full button fill | Strip segment only |

**Key limitation:** The encoder LCD is a **horizontal strip segment**, not a square. Tall text, multi-line labels, and detailed images don't render well. Keep encoder labels to **1 short line** with a value display.

### Good Encoder Display Patterns
```yaml
# Single value display
style:
  text: "Vol: -12dB"
  size: 14

# Label + value
style:
  text: "Master\n-6dB"
  size: 12

# Just a number
style:
  text: "$(yamaha:stereo_level)"
  size: 18
```

### Bad Encoder Display Patterns
```yaml
# TOO MUCH TEXT — won't fit on the strip
style:
  text: "Master Volume\nStereo Output\n-12.5 dB"  # ✗ Three lines
  size: 14

# IMAGE — renders poorly on the strip
style:
  png64: "..."  # ✗ Images don't work well on encoder LCD

# LARGE FONT — clips
style:
  text: "VOL"
  size: 44  # ✗ Way too large for the strip height
```

## Touch LCD Strip

The horizontal LCD strip between the buttons and encoders is touch-sensitive. Each encoder's strip zone supports:

| Touch Event | Trigger | Use Case |
|-------------|---------|----------|
| **Touch** | Finger touches the strip zone | Show value, temporary display |
| **Swipe Left** | Swipe left across zone | Page down, previous option |
| **Swipe Right** | Swipe right across zone | Page up, next option |

**Touch limitations:**
- No multi-touch (one zone at a time)
- No pressure sensitivity
- Swipe detection is basic — works for page navigation, not for precise control
- Touch events fire on the encoder's action config, not separately

## Rotation Behavior

### Step-Based (Not Continuous)

Companion receives **discrete step events**, not a continuous value. Each "click" of the encoder fires one `rotate_cw` or `rotate_ccw` action. Turning faster produces more step events in rapid succession, but each step is identical.

**What this means:**
- You set a **step size** in each action (e.g., +1 dB, +5%, +10 units)
- There's no "acceleration" — fast turns just fire more steps
- Fine control requires small step sizes; coarse control requires large step sizes
- You CAN'T read the absolute encoder position — only relative changes

### Good Step Sizes by Use Case

| Use Case | Step Size | Notes |
|----------|-----------|-------|
| Audio fader (dB) | 0.5 - 1.0 dB | Fine control needed; -∞ to +10dB range |
| Light brightness (%) | 5 - 10% | Coarse is fine; 0-100% range |
| EQ frequency | 10 - 50 Hz | Depends on range (20Hz-20kHz) |
| EQ gain | 0.5 - 1.0 dB | Fine control; -15 to +15dB typical |
| Camera zoom | 1-5 speed units | Depends on module's zoom speed range |
| Camera focus | 1-5 speed units | Fine focus needs small steps |
| Transition position | 100-500 / 10000 | T-bar manual control |
| Timer adjust | 5-15 seconds | Coarse adjustment |

### Rotation + Press Combo

The most powerful encoder pattern: **rotate to adjust, press to toggle/reset.**

```yaml
# Volume encoder: rotate = adjust, press = mute toggle
style:
  text: "Master\n$(yamaha:stereo_level)"
  size: 14
actions:
  rotate_cw:
    - action: yamaha:stereo_master_step
      options: { step: 1 }      # +1 dB
  rotate_ccw:
    - action: yamaha:stereo_master_step
      options: { step: -1 }     # -1 dB
  down:
    - action: yamaha:channel_mute_toggle
      options: { channel: "stereo" }
  long_press:
    - action: yamaha:stereo_master_set
      options: { level: 0 }     # Reset to 0 dB (unity)
feedbacks:
  - type: yamaha:channel_muted
    options: { channel: "stereo" }
    style:
      bgcolor: "#CC0000"
      text: "MUTED"
```

## Limitations and Pitfalls

### 1. No Absolute Position

Encoders are **relative-only** (infinite rotation). There's no "encoder at position 50%." If the physical knob and the actual value get out of sync (e.g., after a scene recall changes the fader level), the display shows the correct value but the encoder still moves relatively from wherever it is.

**Workaround:** Always show the actual value from a variable/feedback, not a calculated position. Users see the real value, not a predicted one.

### 2. No Acceleration

Turning the encoder fast produces more events but each event is the same step size. Users expecting "turn fast = big jumps" will be disappointed.

**Workaround:** Use the button press (or long press) for "jump to preset value" alongside the encoder for fine adjustment.

```yaml
# Encoder for fine adjust, press for preset jumps
actions:
  rotate_cw:
    - action: yamaha:channel_fader_step
      options: { channel: 1, step: 0.5 }  # Fine: +0.5 dB
  rotate_ccw:
    - action: yamaha:channel_fader_step
      options: { channel: 1, step: -0.5 } # Fine: -0.5 dB
  down:
    - action: yamaha:channel_fader_set
      options: { channel: 1, level: 0 }    # Jump to unity (0 dB)
  long_press:
    - action: yamaha:channel_fader_set
      options: { channel: 1, level: -96 }  # Jump to -inf (off)
```

### 3. Step Events Can Stack

If you turn the encoder while a delayed action is running, step events queue up. Avoid putting `companion:wait` delays in rotate actions — they'll cause laggy, unpredictable behavior.

**DON'T do this:**
```yaml
# ✗ BAD: delay in rotate action causes stacking
rotate_cw:
  - action: yamaha:channel_fader_step
    options: { step: 1 }
  - action: companion:wait        # ✗ Blocks next rotate event
    options: { time: 100 }
  - action: yamaha:channel_fader_step
    options: { step: 1 }
```

**DO this:**
```yaml
# ✓ GOOD: single action per rotation event, no delays
rotate_cw:
  - action: yamaha:channel_fader_step
    options: { step: 1 }
```

### 4. Don't Use Steps (Multi-Step) on Encoders

Steps (cycling through different action sets on press) don't work well with encoders because:
- The rotate actions are shared across all steps
- Pressing to advance the step AND pressing to toggle a value conflicts
- The LCD display cycles confusingly

**Use steps on the 8 LCD buttons above the encoders instead.** Keep encoders as single-purpose rotary controls.

### 5. Feedback Update Rate

Encoder LCD updates slower than button displays. If you rotate fast while showing a variable value, the display may lag behind the actual value by a few steps.

**Workaround:** This is cosmetic only — the actual value is correct. Users may notice a slight lag in the number displayed but the equipment responds in real-time.

### 6. Don't Map Page Navigation to Encoders

Page up/down on an encoder is tempting but problematic:
- One accidental nudge changes your entire view
- No physical detent to "stop" at a page
- Users lose context instantly

**Use the LCD buttons or touch strip swipe for page navigation instead.**

### 7. Touch Strip Zone Size

Each encoder's touch strip zone is narrow (~25% of the strip width). Fat fingers may accidentally touch adjacent zones. Don't put destructive actions (mute, go-live) on touch events.

## Recommended Encoder Assignments

### Audio Mixing (Best Use Case)

Encoders excel at audio control because mixers are inherently knob-based:

| Encoder | Assignment | Press Action |
|---------|------------|--------------|
| E0 | Master fader | Mute toggle |
| E1 | Channel 1 (Pastor) | Mute toggle |
| E2 | Channel 2 (Music) | Mute toggle |
| E3 | Monitor/headphone level | Solo clear |

### Camera Control

| Encoder | Assignment | Press Action |
|---------|------------|--------------|
| E0 | Camera focus | Auto-focus toggle |
| E1 | Camera zoom | Zoom preset (wide) |
| E2 | Camera iris | Auto-iris toggle |
| E3 | Transition T-bar | Cut (hard cut) |

### Lighting

| Encoder | Assignment | Press Action |
|---------|------------|--------------|
| E0 | Master brightness | All lights toggle |
| E1 | Stage lights | Stage toggle |
| E2 | House lights | House toggle |
| E3 | Color temperature | Reset to default |

### NOT Recommended for Encoders

| Function | Why Not | Use Instead |
|----------|---------|-------------|
| Scene selection | Discrete choices, not continuous | Button grid |
| Page navigation | Accidental nudges change context | Buttons or swipe |
| Toggle-only actions | Wasted rotation capability | Button press |
| Multi-step workflows | Steps conflict with rotate | Button steps |
| Text input | No way to type with a knob | Web UI |
| Timers | Not intuitive; press + time display better | Button with variable display |

## Complete Stream Deck+ Page Example

```yaml
page:
  number: 5
  name: "Audio Control"

buttons:
  # Row 0: Channel select / status
  - row: 0
    col: 0
    style:
      text: "Pastor\n$(yamaha:channel_1_name)"
      bgcolor: "#333333"
    actions:
      down:
        - action: yamaha:cue_bus_assign
          options: { channel: 1 }
    feedbacks:
      - type: yamaha:channel_muted
        options: { channel: 1 }
        style:
          bgcolor: "#CC0000"
          text: "MUTED\n$(yamaha:channel_1_name)"

  - row: 0
    col: 1
    style:
      text: "Music\n$(yamaha:channel_3_name)"
      bgcolor: "#333333"
    actions:
      down:
        - action: yamaha:cue_bus_assign
          options: { channel: 3 }
    feedbacks:
      - type: yamaha:channel_muted
        options: { channel: 3 }
        style:
          bgcolor: "#CC0000"

  - row: 0
    col: 2
    style:
      text: "Scene\n$(yamaha:scene_name)"
      bgcolor: "#0066CC"
    actions:
      down:
        - action: yamaha:scene_increment
      long_press:
        - action: yamaha:scene_recall
          options: { scene: 1 }

  - row: 0
    col: 3
    style:
      text: "← Home"
      bgcolor: "#0066CC"
    actions:
      down:
        - action: internal:page_set
          options: { page: 1 }

  # Row 1: Mute toggles (one per encoder channel)
  - row: 1
    col: 0
    style:
      text: "Mute\nPastor"
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
          text: "MUTED"

  - row: 1
    col: 1
    style:
      text: "Mute\nMusic"
      bgcolor: "#00CC00"
    actions:
      down:
        - action: yamaha:channel_mute_toggle
          options: { channel: 3 }
    feedbacks:
      - type: yamaha:channel_muted
        options: { channel: 3 }
        style:
          bgcolor: "#CC0000"

  - row: 1
    col: 2
    style:
      text: "Mute\nMedia"
      bgcolor: "#00CC00"
    actions:
      down:
        - action: yamaha:channel_mute_toggle
          options: { channel: 9 }
    feedbacks:
      - type: yamaha:channel_muted
        options: { channel: 9 }
        style:
          bgcolor: "#CC0000"

  - row: 1
    col: 3
    style:
      text: "MUTE ALL"
      bgcolor: "#CC0000"
    actions:
      down:
        - action: yamaha:stereo_master_mute
          options: { mute: true }
      long_press:
        - action: yamaha:stereo_master_mute
          options: { mute: false }
    feedbacks:
      - type: yamaha:channel_muted
        options: { channel: "stereo" }
        style:
          bgcolor: "#FF0000"
          text: "ALL MUTED"

# Encoders: E0-E3 (below the buttons)
encoders:
  - encoder: 0
    style:
      text: "$(yamaha:channel_1_fader)"
      size: 14
    actions:
      rotate_cw:
        - action: yamaha:channel_fader_step
          options: { channel: 1, step: 0.5 }
      rotate_ccw:
        - action: yamaha:channel_fader_step
          options: { channel: 1, step: -0.5 }
      down:
        - action: yamaha:channel_mute_toggle
          options: { channel: 1 }
      long_press:
        - action: yamaha:channel_fader_set
          options: { channel: 1, level: 0 }  # Reset to unity
    feedbacks:
      - type: yamaha:channel_muted
        options: { channel: 1 }
        style:
          bgcolor: "#CC0000"
          text: "MUTED"

  - encoder: 1
    style:
      text: "$(yamaha:channel_3_fader)"
    actions:
      rotate_cw:
        - action: yamaha:channel_fader_step
          options: { channel: 3, step: 0.5 }
      rotate_ccw:
        - action: yamaha:channel_fader_step
          options: { channel: 3, step: -0.5 }
      down:
        - action: yamaha:channel_mute_toggle
          options: { channel: 3 }

  - encoder: 2
    style:
      text: "$(yamaha:channel_9_fader)"
    actions:
      rotate_cw:
        - action: yamaha:channel_fader_step
          options: { channel: 9, step: 0.5 }
      rotate_ccw:
        - action: yamaha:channel_fader_step
          options: { channel: 9, step: -0.5 }
      down:
        - action: yamaha:channel_mute_toggle
          options: { channel: 9 }

  - encoder: 3
    style:
      text: "$(yamaha:stereo_level)"
    actions:
      rotate_cw:
        - action: yamaha:stereo_master_step
          options: { step: 0.5 }
      rotate_ccw:
        - action: yamaha:stereo_master_step
          options: { step: -0.5 }
      down:
        - action: yamaha:channel_mute_toggle
          options: { channel: "stereo" }
      long_press:
        - action: yamaha:stereo_master_set
          options: { level: 0 }
    feedbacks:
      - type: yamaha:channel_muted
        options: { channel: "stereo" }
        style:
          bgcolor: "#CC0000"
          text: "MUTED"
```
