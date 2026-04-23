# Blackmagic ATEM Integration

## Module
`bmd-atem`

## Connection
| Setting | Value |
|---------|-------|
| Host | ATEM IP (Mini default: 192.168.10.240) |
| Protocol | TCP port 9910 |

**Setup:** ATEM must be on the network (USB control not supported by Companion). Model auto-detected on connection. Firmware >= 7.5.2 required.

## Available Actions
- **Set Program Input** — switch live (program) source
- **Set Preview Input** — set preview source
- **Auto Transition** — execute the current transition
- **Cut Transition** — hard cut
- **Set Transition Type** — mix, dip, wipe, stinger, DVE
- **Set Transition Duration** — in frames
- **Toggle Downstream Key** — DSK on/off (overlays, lower thirds)
- **Toggle Upstream Key** — USK on/off (picture-in-picture, chroma key)
- **Toggle FTB** — fade to black
- **Set Aux Source** — change auxiliary output routing
- **Run Macro** — trigger ATEM macros
- **Set Media Player Source** — select media pool clip/still

## Available Feedbacks
- **Program Tally** — red when source is live on program
- **Preview Tally** — green when source is on preview
- **Transition In Progress** — during auto transition
- **FTB Active** — fade to black state
- **DSK On Air** — downstream key active
- **USK On Air** — upstream key active
- **Streaming Status** (ATEM Mini Pro+) — streaming active
- **Recording Status** (ATEM Mini Pro+) — recording active

## Common Button Patterns
```yaml
# Camera input with program/preview tally
- type: button
  text: "CAM 1\nカメラ1"
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
  text: "AUTO\n切替"
  color: "#CCCC00"
  actions:
    down:
      - action: atem:auto_transition
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
- **Can't connect** — ATEM must be on same subnet; check IP with ATEM Software Control
- **Tally not updating** — firmware too old, update via ATEM Software Control
- **Inputs wrong** — input numbers are ATEM-specific, verify in ATEM Software Control
- **Transition not executing** — check that preview source differs from program
