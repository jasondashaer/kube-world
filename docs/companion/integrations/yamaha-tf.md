# Yamaha TF Series Integration

## Module
`yamaha-rcp` (v3.5.10)

## Connection Config (confirmed working)
```yaml
- id: yamaha
  module: "yamaha-rcp"
  label: "Yamaha TF5"
  enabled: true
  config:
    host: "192.168.1.54"
    model: "TF"
```

**Critical**: Set `isFirstInit: true` in the generator to skip upgrade scripts that crash on fresh connections. The `model` field must be the string `"TF"` (not a number).

| Setting | Value |
|---------|-------|
| Host | Mixer IP address |
| Model | `"TF"` (string, from dropdown: CL/QL, PM, TF, DM3, DM7, RIO, TIO, RSIO) |

**Setup:** Requires physical network connection to the mixer. Does NOT work with TF Editor software alone. TF1 = 16ch, TF3 = 24ch, TF5 = 32ch (40 input channels with stereo inputs).

## Confirmed Working Action IDs (RCP)

Action IDs use the RCP address format with `/` separators:

| Action | definitionId | Options |
|--------|-------------|---------|
| Channel Mute | `MIXER_Current/InCh/Fader/On` | X=ch#, Val=0(mute)/1(on)/Toggle |
| Channel Level | `MIXER_Current/InCh/Fader/Level` | X=ch#, Val=-32768 to 1000 |
| Stereo Master Mute | `MIXER_Current/St/Fader/On` | X=1, Val=0/1/Toggle |
| Stereo Master Level | `MIXER_Current/St/Fader/Level` | X=1, Val=-32768 to 1000 |
| Aux/Mix Bus Mute | `MIXER_Current/Mix/Fader/On` | X=bus#, Val=0/1/Toggle |
| Aux/Mix Bus Level | `MIXER_Current/Mix/Fader/Level` | X=bus#, Val=-32768 to 1000 |
| DCA Mute | `MIXER_Current/DCA/Fader/On` | X=DCA#, Val=0/1/Toggle |
| DCA Level | `MIXER_Current/DCA/Fader/Level` | X=DCA#, Val=-32768 to 1000 |
| Scene Recall (TF) | `MIXER_Lib/Bank/Scene/Recall` | X=bank#, Y=1(A)/2(B) |

### Fader Value Scale
- `-32768` = -∞ dB (silence)
- `-2000` = -20 dB
- `-600` = -6 dB
- `0` = 0 dB (unity)
- `1000` = +10 dB (max)
- **100 units = 1 dB**

### Mute Logic (inverted!)
- `Fader/On = 1` means channel is **ON** (unmuted)
- `Fader/On = 0` means channel is **MUTED**
- `Val = "Toggle"` toggles between states

## Smooth Fading (Software-Implemented)

The Yamaha TF RCP protocol has no native fade duration parameter. Smooth fades are implemented by sending multiple level commands with Companion `internal:wait` delays between them.

### Duck Button Pattern (-20dB fade over 1 second)
```
20 steps × 50ms = 1 second total
Each step: set stereo level + set aux level + wait 50ms
1dB per step (Val changes by -100 per step)
```

### Multi-Bus Fading with Offset
When fading multiple buses simultaneously (e.g. stereo master + front fill aux), maintain the dB offset throughout:
```
Stereo master: 0dB → -20dB (Val: 0 → -2000)
Aux 17 (front fills at -6dB offset): -6dB → -26dB (Val: -600 → -2600)
```
Both move -20dB together, preserving the 6dB gap.

### Limitations
- Assumes a fixed starting level (0dB for master, -6dB for aux)
- If mixer state drifts from expected (e.g. Companion restarts), first press may jump
- Workaround: recall a scene before using duck to ensure known fader positions
- Future: use auto-create variable feedback to read actual fader level before fading

## Variables (from connected mixer)

| Variable | Description |
|----------|-------------|
| `$(Yamaha_TF5:modelName)` | Device model (e.g. "TF5") |
| `$(Yamaha_TF5:curScene)` | Current scene ID (e.g. "B08") |
| `$(Yamaha_TF5:curSceneName)` | Current scene name |
| `$(Yamaha_TF5:runMode)` | Device run mode (e.g. "normal") |

*Note: Variable prefix uses the connection label (e.g. `Yamaha_TF5:`) not the module ID.*
*Additional variables are created when feedbacks with "Auto-Create Variable" are enabled.*

## Available Actions (200+ dynamically generated)

Actions are generated from parameter files covering every mixer function. The exact count depends on the model selected.

### Channel Fader / Level
- **Channel Fader Level** -- set fader level (dB or 0-100%)
- **Channel Fader Step** -- increment/decrement fader by step value
- **Channel Fader to Nominal** -- set fader to 0 dB (unity)
- **Channel Fader to -Inf** -- set fader to -infinity (off)
- **DCA Fader Level** -- set DCA group fader level
- **DCA Fader Step** -- increment/decrement DCA fader
- **Stereo Master Level** -- main output fader
- **Stereo Master Step** -- increment/decrement master fader
- **Output Fader Level** -- set bus/aux/matrix output fader
- **Output Fader Step** -- increment/decrement output fader

### Channel Mute / On
- **Channel Mute** -- mute/unmute input channel
- **Channel Mute Toggle** -- toggle mute state
- **Channel On** -- channel on/off
- **DCA Mute** -- mute/unmute DCA group
- **DCA Mute Toggle** -- toggle DCA mute
- **Output Mute** -- mute bus/aux/matrix output
- **Output Mute Toggle** -- toggle output mute

### EQ (Equalizer)
- **Channel EQ On** -- enable/disable channel EQ
- **Channel EQ Type** -- set EQ band type (parametric, shelving, HPF, LPF)
- **Channel EQ Frequency** -- set EQ band center frequency
- **Channel EQ Gain** -- set EQ band gain (+/- dB)
- **Channel EQ Q** -- set EQ band Q/bandwidth
- **Channel HPF Frequency** -- set high-pass filter frequency
- **Channel HPF On** -- enable/disable high-pass filter

### Dynamics
- **Channel Dynamics On** -- enable/disable dynamics processor
- **Channel Gate Threshold** -- set noise gate threshold
- **Channel Gate Range** -- set noise gate range
- **Channel Gate Attack** -- set noise gate attack time
- **Channel Gate Release** -- set noise gate release time
- **Channel Comp Threshold** -- set compressor threshold
- **Channel Comp Ratio** -- set compressor ratio
- **Channel Comp Attack** -- set compressor attack time
- **Channel Comp Release** -- set compressor release time
- **Channel Comp Gain** -- set compressor makeup gain

### Routing
- **Channel Input Patch** -- set input source for a channel
- **Channel Direct Out** -- enable/configure direct output
- **Channel Insert** -- enable/configure channel insert point

### Mix Send / Aux Send
- **Mix Send Level** -- set send level from channel to mix bus
- **Mix Send Step** -- increment/decrement send level
- **Mix Send On** -- enable/disable send from channel to mix
- **Aux Send Level** -- set auxiliary send level
- **Aux Send Step** -- increment/decrement aux send level

### Bus / Matrix
- **Bus Send Level** -- adjust bus send from a channel
- **Matrix Send Level** -- set matrix send level
- **Matrix Level** -- adjust matrix output

### Scenes
- **Scene Recall** -- recall a stored scene (preset)
- **Scene Store** -- store current settings to a scene
- **Scene Increment** -- recall next scene
- **Scene Decrement** -- recall previous scene

### Cue / Solo
- **Cue Bus Assign** -- assign channel to cue bus (monitor)
- **Cue Bus Clear** -- clear all cue assignments

### Metering
- **Metering Subscribe** -- subscribe to metering data for channels
- **Metering Unsubscribe** -- unsubscribe from metering data

## Available Feedbacks (200+ dynamically generated)

Feedbacks mirror the actions -- each parameter that can be set also has a corresponding feedback for its current state.

### Channel State
- **Channel Mute Status** -- muted/unmuted per channel
- **Channel On Status** -- on/off per channel
- **Channel Fader Level** -- current fader position
- **Channel Fader dB** -- fader level in dB display

### DCA State
- **DCA Mute Status** -- per DCA group
- **DCA Fader Level** -- per DCA fader position

### EQ State
- **Channel EQ On Status** -- EQ enabled/disabled
- **Channel EQ Band Gain** -- current gain per band
- **Channel HPF Status** -- HPF on/off

### Dynamics State
- **Channel Dynamics On Status** -- dynamics enabled/disabled
- **Channel Gate Status** -- gate open/closed indicator
- **Channel Comp GR** -- compressor gain reduction meter

### Output State
- **Output Mute Status** -- muted/unmuted per output
- **Output Fader Level** -- current output fader

### Mix Send State
- **Mix Send Level** -- current send level
- **Mix Send On Status** -- send enabled/disabled

### Scene
- **Scene Active** -- currently recalled scene number
- **Scene Name** -- name of the active scene

### Metering
- **Channel Meter Level** -- real-time input meter level
- **Output Meter Level** -- real-time output meter level
- **DCA Meter Level** -- DCA group meter level

### Connection
- **Connection Status** -- connected/disconnected

## Available Variables (50+)

| Variable | Description |
|----------|-------------|
| `$(yamaha:channel_N_fader)` | Channel N fader level (dB) |
| `$(yamaha:channel_N_mute)` | Channel N mute state |
| `$(yamaha:channel_N_name)` | Channel N scribble strip name |
| `$(yamaha:channel_N_on)` | Channel N on/off state |
| `$(yamaha:channel_N_meter)` | Channel N meter level (with metering enabled) |
| `$(yamaha:dca_N_fader)` | DCA N fader level |
| `$(yamaha:dca_N_mute)` | DCA N mute state |
| `$(yamaha:dca_N_name)` | DCA N name |
| `$(yamaha:stereo_level)` | Stereo master fader level |
| `$(yamaha:stereo_mute)` | Stereo master mute state |
| `$(yamaha:output_N_fader)` | Output N fader level |
| `$(yamaha:output_N_mute)` | Output N mute state |
| `$(yamaha:output_N_name)` | Output N name |
| `$(yamaha:bus_N_fader)` | Bus N fader level |
| `$(yamaha:bus_N_mute)` | Bus N mute state |
| `$(yamaha:scene_current)` | Currently active scene number |
| `$(yamaha:scene_name)` | Currently active scene name |
| `$(yamaha:scene_comment)` | Scene comment text |
| `$(yamaha:mix_send_N_M_level)` | Send level from channel N to mix M |
| `$(yamaha:mix_send_N_M_on)` | Send on/off from channel N to mix M |

## Common Button Patterns
```yaml
# Channel mute toggle with status
- type: button
  text: "Pastor"
  color: "#00CC00"
  actions:
    down:
      - action: yamaha:channel_mute_toggle
        options:
          channel: 1
  feedbacks:
    - type: yamaha:channel_muted
      options:
        channel: 1
      style:
        bgcolor: "#CC0000"
        text: "MUTED"

# Scene recall for service presets
- type: button
  text: "Sunday"
  color: "#0066CC"
  actions:
    down:
      - action: yamaha:scene_recall
        options:
          scene: 1

# EQ adjustment with encoder -- HPF frequency
- type: button
  text: "HPF Ch1\n$(yamaha:channel_1_name)"
  color: "#333333"
  actions:
    rotate_cw:
      - action: yamaha:channel_hpf_frequency
        options:
          channel: 1
          adjustment: 10  # +10 Hz
    rotate_ccw:
      - action: yamaha:channel_hpf_frequency
        options:
          channel: 1
          adjustment: -10  # -10 Hz
    down:
      - action: yamaha:channel_hpf_on
        options:
          channel: 1
          state: "toggle"
  feedbacks:
    - type: yamaha:channel_hpf_status
      options:
        channel: 1
      style:
        bgcolor: "#006600"
        text: "HPF ON\n$(yamaha:channel_1_name)"

# Dynamics control -- compressor threshold with encoder
- type: button
  text: "Comp Ch1\n$(yamaha:channel_1_name)"
  color: "#333333"
  actions:
    rotate_cw:
      - action: yamaha:channel_comp_threshold
        options:
          channel: 1
          adjustment: 1  # +1 dB
    rotate_ccw:
      - action: yamaha:channel_comp_threshold
        options:
          channel: 1
          adjustment: -1  # -1 dB
    down:
      - action: yamaha:channel_dynamics_on
        options:
          channel: 1
          state: "toggle"
  feedbacks:
    - type: yamaha:channel_dynamics_on
      options:
        channel: 1
      style:
        bgcolor: "#990099"
        text: "Comp ON\n$(yamaha:channel_1_name)"

# Bus send control with encoder -- monitor mix
- type: button
  text: "Mon Send\nCh1>Mix1"
  color: "#333333"
  actions:
    rotate_cw:
      - action: yamaha:mix_send_step
        options:
          channel: 1
          mix: 1
          step: 1
    rotate_ccw:
      - action: yamaha:mix_send_step
        options:
          channel: 1
          mix: 1
          step: -1
    down:
      - action: yamaha:mix_send_on
        options:
          channel: 1
          mix: 1
          state: "toggle"
  feedbacks:
    - type: yamaha:mix_send_on
      options:
        channel: 1
        mix: 1
      style:
        bgcolor: "#006666"
        text: "Send ON\n$(yamaha:mix_send_1_1_level) dB"

# Metering display -- channel level with color thresholds
- type: button
  text: "$(yamaha:channel_1_name)\n$(yamaha:channel_1_meter) dB"
  color: "#333333"
  actions:
    down:
      - action: yamaha:cue_bus_assign
        options:
          channel: 1
    long_press:
      - action: yamaha:cue_bus_clear
  feedbacks:
    - type: yamaha:channel_muted
      options:
        channel: 1
      style:
        bgcolor: "#CC0000"
        text: "MUTED\n$(yamaha:channel_1_name)"
    - type: yamaha:connection_status
      style:
        bgcolor: "#003300"

# DCA group control with fader display
- type: button
  text: "Band\n$(yamaha:dca_1_fader) dB"
  color: "#333333"
  actions:
    rotate_cw:
      - action: yamaha:dca_fader_step
        options:
          dca: 1
          step: 1
    rotate_ccw:
      - action: yamaha:dca_fader_step
        options:
          dca: 1
          step: -1
    down:
      - action: yamaha:dca_mute_toggle
        options:
          dca: 1
  feedbacks:
    - type: yamaha:dca_muted
      options:
        dca: 1
      style:
        bgcolor: "#CC0000"
        text: "MUTED\n$(yamaha:dca_1_name)"

# Push-to-talk: unmute while held, re-mute on release
- type: button
  text: "PTT\n$(yamaha:channel_2_name)"
  color: "#CC0000"
  actions:
    down:
      - action: yamaha:channel_mute_set
        options:
          channel: 2
          mute: false
    up:
      - action: yamaha:channel_mute_set
        options:
          channel: 2
          mute: true
  feedbacks:
    - type: yamaha:channel_muted
      options:
        channel: 2
      style:
        bgcolor: "#CC0000"
        text: "MUTED\n$(yamaha:channel_2_name)"
```

## Channel Map Template
Document which channel corresponds to which source:

| Channel | Source | Label | Notes |
|---------|--------|-------|-------|
| 1 | Pastor mic | Pastor | Wireless handheld |
| 2 | Worship leader | Worship | Wireless headset |
| 3 | Guitar | Guitar | DI box |
| 4 | Keyboard L | Keys L | Stereo pair |
| 5 | Keyboard R | Keys R | Stereo pair |
| 6-8 | Choir mics | Choir | Condenser overheads |
| 9-10 | Playback L/R | Media | Computer audio |
| ST | Main output | Master | House speakers |

## Troubleshooting
- **Can't connect** -- TF must be on same network; check IP in TF Settings > Network
- **RCP not responding** -- restart TF1 network; some firmware versions need power cycle
- **Scene recall fails** -- scene number must exist on the mixer
- **Fader values wrong** -- TF uses -inf to +10dB scale; Companion may use 0-100%
- **Metering not showing** -- enable Metering in module connection settings; set interval (100ms recommended)
- **Bonjour not finding mixer** -- Bonjour requires both devices on same VLAN; check mDNS/Bonjour service
- **EQ/dynamics not responding** -- verify channel number matches; some parameters require specific processing modes
