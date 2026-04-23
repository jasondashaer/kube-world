# ProPresenter Integration

## Module
`renewedvision-propresenter-api` (for ProPresenter 7.9+)

Legacy alternative: `renewedvision-propresenter` (PP 6-20, WebSocket-based)

## Connection
| Setting | Value |
|---------|-------|
| Host | IP of ProPresenter machine |
| Port | 1025 (default, but PP assigns random -- must lock in PP settings) |
| Protocol | HTTP REST API |

**Setup:** PP > Settings > Network > type port number and press Enter to lock it.

## Available Actions (22)

### Presentation Operations
- **Trigger Slide** -- go to specific slide by index or name
- **Next Slide** -- advance to next slide in active presentation
- **Previous Slide** -- go back one slide
- **Trigger Playlist Item** -- jump to a specific item in playlist
- **Go to Group** -- navigate to a slide group (slides, media)
- **Active Presentation Focus** -- bring focus to active presentation

### Announcement Operations
- **Trigger Announcement** -- show an announcement slide
- **Active Announcement Next** -- advance to next announcement slide
- **Active Announcement Previous** -- go to previous announcement slide
- **Active Announcement Index** -- jump to specific announcement by index
- **Clear Announcements** -- remove announcements from output

### Audio Playlist Operations
- **Audio Playlist Trigger** -- start playback of an audio playlist item
- **Audio Playlist Next** -- advance to next audio item
- **Audio Playlist Previous** -- go to previous audio item
- **Audio Playlist Focused** -- set focus on an audio playlist

### Clear / Layer Operations
- **Clear Layer** -- clear slides, media, props, messages, audio, or all layers

### Timer Operations
- **Start Timer** -- start a countdown/countup timer by name or ID
- **Stop Timer** -- stop a running timer
- **Reset Timer** -- reset timer to its configured value

### Message / Props / Video Input
- **Show Message** -- show a message with token values on output
- **Stage Display Layout** -- switch stage display configurations

### Capture / Macros
- **Trigger Macro** -- run a ProPresenter macro by name or index

## Available Feedbacks (6)
- **Current Slide** -- shows current slide text/index
- **Active Presentation** -- which presentation is currently loaded
- **Timer Status** -- running, paused, or expired state
- **Connection Status** -- connected/disconnected to ProPresenter instance
- **Active Announcement** -- whether an announcement is currently showing
- **Playlist Active** -- which playlist item is currently active

## Available Variables (40+)

### Machine Info
| Variable | Description |
|----------|-------------|
| `$(propresenter:machine_name)` | ProPresenter machine hostname |
| `$(propresenter:os_version)` | Operating system version |
| `$(propresenter:pp_version)` | ProPresenter application version |

### Active Presentation
| Variable | Description |
|----------|-------------|
| `$(propresenter:active_presentation_name)` | Name of the current presentation |
| `$(propresenter:active_presentation_uuid)` | UUID of the current presentation |
| `$(propresenter:current_slide_index)` | Current slide index (0-based) |
| `$(propresenter:current_slide_text)` | Text content of the current slide |
| `$(propresenter:current_slide_notes)` | Presenter notes for the current slide |
| `$(propresenter:current_slide_uuid)` | UUID of the current slide |
| `$(propresenter:total_slides)` | Total number of slides in active presentation |
| `$(propresenter:remaining_slides)` | Slides remaining after current |

### Announcements
| Variable | Description |
|----------|-------------|
| `$(propresenter:announcement_active)` | Whether an announcement is showing (true/false) |
| `$(propresenter:announcement_slide_index)` | Current announcement slide index |
| `$(propresenter:announcement_text)` | Text of the current announcement |

### Audio Playlists
| Variable | Description |
|----------|-------------|
| `$(propresenter:audio_playlist_name)` | Name of the active audio playlist |
| `$(propresenter:audio_item_name)` | Name of the currently playing audio item |
| `$(propresenter:audio_item_artist)` | Artist of the currently playing audio item |
| `$(propresenter:audio_item_duration)` | Duration of the current audio item |
| `$(propresenter:audio_item_elapsed)` | Elapsed time of the current audio item |
| `$(propresenter:audio_item_remaining)` | Remaining time of the current audio item |

### Timers
| Variable | Description |
|----------|-------------|
| `$(propresenter:timer_N_current)` | Current value of timer N (formatted) |
| `$(propresenter:timer_N_name)` | Name of timer N |
| `$(propresenter:timer_N_status)` | Status of timer N (running/stopped/expired) |
| `$(propresenter:timer_N_duration)` | Configured duration of timer N |

### Playlist
| Variable | Description |
|----------|-------------|
| `$(propresenter:playlist_name)` | Name of active playlist |
| `$(propresenter:playlist_index)` | Index of active item in playlist |

**237+ presets available** covering quick-trigger buttons for common slide operations, timer controls, layer clears, and macro triggers.

## Common Button Patterns
```yaml
# Next slide with current slide preview
- type: button
  text: "Next\n$(propresenter:current_slide_index)/$(propresenter:total_slides)"
  color: "#00CC00"
  actions:
    down:
      - action: propresenter:next_slide
  feedbacks:
    - type: propresenter:active_presentation
      style:
        text: "Next\n$(propresenter:current_slide_index)/$(propresenter:total_slides)"
    - type: propresenter:connection_status
      style:
        bgcolor: "#00CC00"

# Timer control with countdown display
- type: button
  text: "Timer\n$(propresenter:timer_1_current)"
  color: "#333333"
  actions:
    down:
      - action: propresenter:timer_start
        options:
          timer: "Sermon Timer"
    long_press:
      - action: propresenter:timer_stop
        options:
          timer: "Sermon Timer"
    double_press:
      - action: propresenter:timer_reset
        options:
          timer: "Sermon Timer"
  feedbacks:
    - type: propresenter:timer_status
      options:
        timer: "Sermon Timer"
        status: "running"
      style:
        bgcolor: "#00CC00"
        text: "$(propresenter:timer_1_current)"
    - type: propresenter:timer_status
      options:
        timer: "Sermon Timer"
        status: "expired"
      style:
        bgcolor: "#CC0000"
        text: "TIME UP!"

# Macro trigger button
- type: button
  text: "Macro\nPre-Service"
  color: "#9900CC"
  actions:
    down:
      - action: propresenter:trigger_macro
        options:
          macro: "Pre-Service Setup"
  feedbacks:
    - type: propresenter:connection_status
      style:
        bgcolor: "#333333"

# Announcement operations -- show then auto-advance
- type: button
  text: "Announce"
  color: "#CC6600"
  actions:
    down:
      - action: propresenter:trigger_announcement
        options:
          index: 0
    long_press:
      - action: propresenter:clear_announcements
  feedbacks:
    - type: propresenter:active_announcement
      style:
        bgcolor: "#CC6600"
        text: "ANNOUNCE\n$(propresenter:announcement_text)"

# Audio playlist control with press-and-hold pattern
- type: button
  text: "Music\n$(propresenter:audio_item_name)"
  color: "#0066CC"
  actions:
    down:
      - action: propresenter:audio_playlist_next
    up:
      []  # No release action
    long_press:
      - action: propresenter:audio_playlist_trigger
        options:
          playlist: "Worship Music"
  feedbacks:
    - type: propresenter:connection_status
      style:
        text: "Music\n$(propresenter:audio_item_name)\n$(propresenter:audio_item_remaining)"

# Multi-step service sequence
- type: button
  text: "Service\nStart"
  color: "#0066CC"
  steps:
    - style:
        text: "Start\nService"
        bgcolor: "#0066CC"
      actions:
        down:
          - action: propresenter:trigger_playlist
            options:
              playlist: "Sunday Service"
          - action: propresenter:timer_start
            options:
              timer: "Service Timer"

    - style:
        text: "Next\nItem"
        bgcolor: "#00CC00"
      actions:
        down:
          - action: propresenter:next_slide
      feedbacks:
        - type: propresenter:active_presentation
          style:
            text: "$(propresenter:active_presentation_name)\n$(propresenter:current_slide_index)/$(propresenter:total_slides)"
```

## Troubleshooting
- **"Unexpected Server Response: 404"** -- legacy module needs password set in PP Network settings
- **Connection drops** -- PP port reverts to random on restart; lock it in settings
- **No slides showing** -- verify presentation is open AND in playlist
- **Timer not starting** -- timer name must match exactly as configured in ProPresenter
- **Macro not triggering** -- verify macro name/index matches; macros are case-sensitive
