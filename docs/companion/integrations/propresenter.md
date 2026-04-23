# ProPresenter Integration

## Module
`renewedvision-propresenter-api` (for ProPresenter 7.9+)

Legacy alternative: `renewedvision-propresenter` (PP 6-20, WebSocket-based)

## Connection
| Setting | Value |
|---------|-------|
| Host | IP of ProPresenter machine |
| Port | 1025 (default, but PP assigns random — must lock in PP settings) |
| Protocol | HTTP REST API |

**Setup:** PP > Settings > Network > type port number and press Enter to lock it.

## Available Actions
- **Trigger Slide** — go to specific slide by index or name
- **Next Slide / Previous Slide** — advance presentation
- **Trigger Playlist Item** — jump to a specific item in playlist
- **Clear Layer** — clear slides, media, props, messages, audio
- **Start/Stop Timer** — control countdown timers
- **Trigger Macro** — run ProPresenter macros
- **Go to Group** (slides, media) — navigate slide groups
- **Stage Display Layout** — switch stage display configurations

## Available Feedbacks
- **Current Slide** — shows current slide text/index
- **Active Presentation** — which presentation is loaded
- **Timer Status** — running, paused, expired
- **Connection Status** — connected/disconnected

## Common Button Patterns
```yaml
# Next slide with current slide preview
- type: button
  text: "Next\n次へ"
  color: "#00CC00"
  actions:
    down:
      - action: propresenter:next_slide
  feedbacks:
    - type: propresenter:current_slide
      style:
        text: "$(propresenter:current_slide_index)"
```

## Troubleshooting
- **"Unexpected Server Response: 404"** — legacy module needs password set in PP Network settings
- **Connection drops** — PP port reverts to random on restart; lock it in settings
- **No slides showing** — verify presentation is open AND in playlist
