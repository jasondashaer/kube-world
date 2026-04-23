# OBS Studio Integration

## Module
`obs-studio`

## Connection
| Setting | Value |
|---------|-------|
| Host | IP of OBS machine |
| Port | 4455 (WebSocket v5 default) |
| Password | Set in OBS WebSocket settings (optional) |
| Protocol | WebSocket v5 |

**Setup:** OBS > Tools > WebSocket Server Settings > Enable. Requires OBS 28+.

## Available Actions
- **Switch Scene** — change active scene
- **Set Scene Transition** — change transition type/duration
- **Toggle Source Visibility** — show/hide sources within a scene
- **Start/Stop Streaming** — control stream output
- **Start/Stop Recording** — control recording
- **Set Audio Mute** — mute/unmute audio sources
- **Set Audio Volume** — adjust source volume (dB)
- **Set Source Filter** — enable/disable source filters
- **Send Hotkey** — trigger OBS hotkeys remotely
- **Set Virtual Camera** — start/stop virtual camera

## Available Feedbacks
- **Streaming Status** — on/off, duration, dropped frames
- **Recording Status** — on/off, duration
- **Current Scene** — active scene name
- **Source Visibility** — visible/hidden per source
- **Audio Muted** — per source mute state
- **Audio Level** — per source volume meter

## Common Button Patterns
```yaml
# Scene switch with tally (green when active)
- type: button
  text: "CAM 1\nカメラ1"
  color: "#666666"
  actions:
    down:
      - action: obs:set_current_scene
        options:
          scene: "Camera 1"
  feedbacks:
    - type: obs:scene_active
      options:
        scene: "Camera 1"
      style:
        bgcolor: "#00CC00"

# Stream toggle with status
- type: button
  text: "STREAM\n配信"
  color: "#CC0000"
  actions:
    down:
      - action: obs:toggle_streaming
  feedbacks:
    - type: obs:streaming
      style:
        bgcolor: "#CC0000"
        text: "LIVE"
```

## Troubleshooting
- **Can't connect** — verify WebSocket server is enabled in OBS Tools menu
- **Password rejected** — check OBS WebSocket settings for the auth token
- **Scene switch lag** — normal, OBS processes transitions asynchronously
- **Audio controls not working** — source names must match exactly (case-sensitive)
