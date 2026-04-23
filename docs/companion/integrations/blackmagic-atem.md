# Blackmagic ATEM Integration

## Module
`bmd-atem`

## Connection
| Setting | Value |
|---------|-------|
| Host | ATEM IP (Mini default: 192.168.10.240) |
| Protocol | TCP port 9910 |

**Setup:** ATEM must be on the network (USB control not supported by Companion). Model auto-detected on connection. Firmware >= 7.5.2 required.

## Available Actions (50+)

### Program / Preview Switching
- **Set Program Input** -- switch live (program) source
- **Set Preview Input** -- set preview source
- **Set Program Input (by variable)** -- switch program using a variable value

### Transitions
- **Auto Transition** -- execute the current transition
- **Cut Transition** -- hard cut
- **Set Transition Type** -- mix, dip, wipe, stinger, DVE
- **Set Transition Duration** -- in frames
- **Set Transition Selection** -- select which layers participate in next transition
- **Set Transition Position** -- manual T-bar position (0-10000)
- **Set Transition Style** -- set next transition style for M/E

### Downstream Keys
- **Toggle Downstream Key** -- DSK on/off (overlays, lower thirds)
- **Set DSK On Air** -- explicitly set DSK state
- **Set DSK Tie** -- tie DSK to next transition
- **DSK Auto** -- auto-transition DSK on/off

### Upstream Keys
- **Toggle Upstream Key** -- USK on/off (picture-in-picture, chroma key)
- **Set USK On Air** -- explicitly set USK state
- **Set USK Type** -- luma, chroma, pattern, DVE
- **Set USK Fill Source** -- set fill source for key
- **Set USK Key Source** -- set key/cut source for key

### Fade to Black
- **Toggle FTB** -- fade to black
- **Set FTB Rate** -- set fade to black duration

### Auxiliary Outputs
- **Set Aux Source** -- change auxiliary output routing

### Media Player
- **Set Media Player Source** -- select media pool clip/still
- **Set Media Player Clip** -- select specific clip slot
- **Set Media Player Still** -- select specific still slot

### Macros
- **Run Macro** -- trigger ATEM macros by index
- **Stop Macro** -- stop a running macro
- **Macro Continue** -- continue a paused macro

### Camera Control
- **Camera Control: Focus** -- adjust camera focus (auto/manual/near/far)
- **Camera Control: Zoom** -- zoom in/out (speed control)
- **Camera Control: Iris** -- adjust iris/aperture
- **Camera Control: Shutter Speed** -- set shutter speed
- **Camera Control: White Balance** -- set white balance (auto/manual/preset)
- **Camera Control: Color Correction** -- lift/gamma/gain/offset per RGBY
- **Camera Control: Gain** -- set camera sensor gain/ISO

### Super Source
- **Set Super Source Box** -- enable/disable/position a super source box
- **Set Super Source Box Source** -- set source for a super source box
- **Set Super Source Box Position** -- set X/Y position and size
- **Set Super Source Box Crop** -- set crop values for a box
- **Super Source Art** -- set super source art (background/foreground)

### Multiviewer
- **Set Multiviewer Window Source** -- change source displayed in a multiviewer window

### Streaming and Recording (ATEM Mini Pro+)
- **Start Streaming** -- begin stream output
- **Stop Streaming** -- end stream output
- **Start Recording** -- begin recording to USB
- **Stop Recording** -- end recording
- **Pause Recording** -- pause active recording
- **Resume Recording** -- resume paused recording
- **Switch Recording Disk** -- switch to next recording disk

### Fairlight Audio
- **Set Fairlight Input Level** -- adjust input gain
- **Set Fairlight Fader Level** -- adjust channel fader (dB)
- **Set Fairlight Mute** -- mute/unmute audio channel
- **Set Fairlight EQ** -- adjust EQ band parameters
- **Set Fairlight Dynamics** -- adjust compressor/gate/limiter
- **Set Fairlight Pan** -- adjust channel pan position

### Timecode
- **Set Timecode** -- set timecode value
- **Request Timecode** -- request current timecode from ATEM

## Available Feedbacks (20+)
- **Program Tally** -- red when source is live on program
- **Preview Tally** -- green when source is on preview
- **Transition In Progress** -- during auto transition
- **Transition Position** -- current T-bar position
- **FTB Active** -- fade to black state
- **FTB In Progress** -- during fade to black transition
- **DSK On Air** -- downstream key active
- **DSK Tie** -- downstream key tied to transition
- **USK On Air** -- upstream key active
- **Streaming Status** (ATEM Mini Pro+) -- streaming active
- **Recording Status** (ATEM Mini Pro+) -- recording active
- **Recording Paused** -- recording is paused
- **Super Source Box Active** -- super source box enabled
- **Multiviewer Window Source** -- matches when source is in multiviewer
- **Timecode** -- current timecode display
- **Macro Active** -- true when a specific macro is running
- **Macro Recording** -- true when macro recording is active
- **Fairlight Mute** -- audio channel mute state
- **Aux Source** -- true when aux is set to specific source
- **Media Player Source** -- true when media player has specific source
- **Connection Status** -- connected/disconnected

## Available Variables (100+)

### Program / Preview
| Variable | Description |
|----------|-------------|
| `$(atem:program_input)` | Current program input number |
| `$(atem:program_input_name)` | Current program input label |
| `$(atem:preview_input)` | Current preview input number |
| `$(atem:preview_input_name)` | Current preview input label |

### Transition
| Variable | Description |
|----------|-------------|
| `$(atem:transition_style)` | Current transition style name |
| `$(atem:transition_duration)` | Transition duration in frames |
| `$(atem:transition_position)` | T-bar position (0-10000) |
| `$(atem:transition_in_progress)` | Whether transition is active |

### Keys
| Variable | Description |
|----------|-------------|
| `$(atem:usk_N_on_air)` | USK N on air state |
| `$(atem:usk_N_type)` | USK N type (luma/chroma/pattern/DVE) |
| `$(atem:dsk_N_on_air)` | DSK N on air state |
| `$(atem:dsk_N_tie)` | DSK N tied to transition |

### Streaming and Recording
| Variable | Description |
|----------|-------------|
| `$(atem:streaming)` | Streaming status |
| `$(atem:stream_duration)` | Stream duration (HH:MM:SS) |
| `$(atem:recording)` | Recording status |
| `$(atem:record_duration)` | Recording duration (HH:MM:SS) |
| `$(atem:record_paused)` | Recording paused state |

### Timecode
| Variable | Description |
|----------|-------------|
| `$(atem:timecode)` | Current timecode (HH:MM:SS:FF) |
| `$(atem:timecode_hours)` | Timecode hours |
| `$(atem:timecode_minutes)` | Timecode minutes |
| `$(atem:timecode_seconds)` | Timecode seconds |
| `$(atem:timecode_frames)` | Timecode frames |

### Fairlight Audio
| Variable | Description |
|----------|-------------|
| `$(atem:fairlight_input_N_level)` | Input N gain level |
| `$(atem:fairlight_fader_N_level)` | Fader N level (dB) |
| `$(atem:fairlight_fader_N_mute)` | Fader N mute state |
| `$(atem:fairlight_master_level)` | Master fader level |

### Super Source
| Variable | Description |
|----------|-------------|
| `$(atem:ssrc_box_N_enabled)` | Super source box N enabled |
| `$(atem:ssrc_box_N_source)` | Super source box N source |
| `$(atem:ssrc_box_N_x)` | Super source box N X position |
| `$(atem:ssrc_box_N_y)` | Super source box N Y position |
| `$(atem:ssrc_box_N_size)` | Super source box N size |

### Auxiliary Outputs
| Variable | Description |
|----------|-------------|
| `$(atem:aux_N_source)` | Aux output N source |
| `$(atem:aux_N_source_name)` | Aux output N source label |

### Media Player
| Variable | Description |
|----------|-------------|
| `$(atem:mp_N_source_type)` | Media player N source type |
| `$(atem:mp_N_source_index)` | Media player N source index |

### Macros
| Variable | Description |
|----------|-------------|
| `$(atem:macro_running)` | Whether a macro is currently running |
| `$(atem:macro_loop)` | Whether macro is set to loop |

**100+ presets available** covering input switching, transition controls, key toggles, macro triggers, and audio controls.

## Common Button Patterns
```yaml
# Camera input with program/preview tally
- type: button
  text: "CAM 1"
  color: "#666666"
  actions:
    down:
      - action: atem:set_preview_input
        options:
          input: 1
  feedbacks:
    - type: atem:program_tally
      options:
        input: 1
      style:
        bgcolor: "#CC0000"  # Red = LIVE
    - type: atem:preview_tally
      options:
        input: 1
      style:
        bgcolor: "#00CC00"  # Green = preview

# Auto transition (cut/mix)
- type: button
  text: "AUTO"
  color: "#CCCC00"
  actions:
    down:
      - action: atem:auto_transition

# Camera control -- focus with encoder
- type: button
  text: "Focus\nCAM 1"
  color: "#333333"
  actions:
    rotate_cw:
      - action: atem:camera_control_focus
        options:
          camera: 1
          direction: "far"
          speed: 0.5
    rotate_ccw:
      - action: atem:camera_control_focus
        options:
          camera: 1
          direction: "near"
          speed: 0.5
    down:
      - action: atem:camera_control_focus
        options:
          camera: 1
          direction: "auto"

# Super source layout control -- toggle boxes
- type: button
  text: "2-Box\nLayout"
  color: "#9900CC"
  actions:
    down:
      - action: atem:set_super_source_box
        options:
          box: 0
          enabled: true
          source: 1
          x: -480
          y: 0
          size: 500
      - action: atem:set_super_source_box
        options:
          box: 1
          enabled: true
          source: 2
          x: 480
          y: 0
          size: 500
      - action: atem:set_super_source_box
        options:
          box: 2
          enabled: false
      - action: atem:set_super_source_box
        options:
          box: 3
          enabled: false
  feedbacks:
    - type: atem:super_source_box_active
      options:
        box: 0
      style:
        bgcolor: "#9900CC"

# Fairlight audio fader with encoder
- type: button
  text: "Pastor\n$(atem:fairlight_fader_1_level) dB"
  color: "#333333"
  actions:
    rotate_cw:
      - action: atem:set_fairlight_fader_level
        options:
          channel: 1
          adjustment: 1  # +1 dB
    rotate_ccw:
      - action: atem:set_fairlight_fader_level
        options:
          channel: 1
          adjustment: -1  # -1 dB
    down:
      - action: atem:set_fairlight_mute
        options:
          channel: 1
          mute: "toggle"
  feedbacks:
    - type: atem:fairlight_mute
      options:
        channel: 1
      style:
        bgcolor: "#CC0000"
        text: "MUTED\n$(atem:fairlight_fader_1_level) dB"

# Macro execution with running status
- type: button
  text: "Macro 1\nIntro"
  color: "#0066CC"
  actions:
    down:
      - action: atem:run_macro
        options:
          macro: 0  # Zero-indexed
    long_press:
      - action: atem:stop_macro
  feedbacks:
    - type: atem:macro_active
      options:
        macro: 0
      style:
        bgcolor: "#CCCC00"
        text: "Running\nMacro 1"
    - type: atem:connection_status
      style:
        bgcolor: "#003300"

# Streaming with recording -- multi-step for Mini Pro
- type: button
  text: "STREAM"
  color: "#666666"
  steps:
    - style:
        text: "GO LIVE"
        bgcolor: "#666666"
      actions:
        down:
          - action: atem:start_streaming
          - action: atem:start_recording

    - style:
        text: "● LIVE\n$(atem:stream_duration)"
        bgcolor: "#CC0000"
      actions:
        down:
          - action: atem:pause_recording
        long_press:
          - action: atem:stop_streaming
          - action: atem:stop_recording
          - action: companion:step_set
            options: { step: 1 }
      feedbacks:
        - type: atem:streaming
          style:
            bgcolor: "#CC0000"
            text: "● LIVE\n$(atem:stream_duration)"
        - type: atem:recording_paused
          style:
            bgcolor: "#CCCC00"
            text: "● LIVE\nREC PAUSED"
```

## Input Mapping
Document which physical input corresponds to which camera/source:

| ATEM Input | Source | Label |
|------------|--------|-------|
| 1 | Camera 1 (wide) | CAM 1 |
| 2 | Camera 2 (close) | CAM 2 |
| 3 | Camera 3 (side) | CAM 3 |
| 4 | Computer (slides) | PC |
| 1000 | Color Bars | BARS |
| 2001 | Media Player 1 | MP1 |
| 10010 | Color 1 | BLK |

## Troubleshooting
- **Can't connect** -- ATEM must be on same subnet; check IP with ATEM Software Control
- **Tally not updating** -- firmware too old, update via ATEM Software Control
- **Inputs wrong** -- input numbers are ATEM-specific, verify in ATEM Software Control
- **Transition not executing** -- check that preview source differs from program
- **Camera control not working** -- requires Blackmagic cameras connected via SDI with camera control protocol
- **Super source unavailable** -- only available on ATEM models that support super source (not Mini)
- **Fairlight audio not responding** -- requires ATEM models with Fairlight audio engine
- **Macro not found** -- macro index is zero-based; macro must exist on the switcher
