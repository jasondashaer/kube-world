# Yamaha TF Series Integration

## Module
`yamaha-rcp`

## Connection
| Setting | Value |
|---------|-------|
| Host | TF1 IP address |
| Port | 49280 (RCP protocol, auto) |
| Model | TF |
| Protocol | TCP/RCP |

**Setup:** Requires physical network connection to the mixer. Does NOT work with TF Editor software alone. TF1 has 16 input channels + stereo out + 20 AUX/bus/matrix.

## Available Actions
- **Channel Fader** — set fader level (dB or %)
- **Channel Mute** — mute/unmute input channel
- **Channel On** — channel on/off
- **DCA Mute** — mute/unmute DCA group
- **DCA Level** — set DCA fader level
- **Scene Recall** — recall a stored scene (preset)
- **Bus Send Level** — adjust aux/bus send from a channel
- **Matrix Level** — adjust matrix output
- **Stereo Master Level** — main output fader

## Available Feedbacks
- **Channel Mute Status** — muted/unmuted per channel
- **Channel Fader Level** — current fader position
- **DCA Mute Status** — per DCA group
- **Scene Active** — currently recalled scene number

## Common Button Patterns
```yaml
# Channel mute toggle with status
- type: button
  text: "Pastor\n牧師"
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
        text: "MUTED\nミュート"

# Scene recall for service presets
- type: button
  text: "Sunday\n日曜"
  color: "#0066CC"
  actions:
    down:
      - action: yamaha:scene_recall
        options:
          scene: 1
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
- **Can't connect** — TF must be on same network; check IP in TF Settings > Network
- **RCP not responding** — restart TF1 network; some firmware versions need power cycle
- **Scene recall fails** — scene number must exist on the mixer
- **Fader values wrong** — TF uses -∞ to +10dB scale; Companion may use 0-100%
