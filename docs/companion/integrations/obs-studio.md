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

## Available Actions (33)

### Scene Operations
- **Switch Scene** -- change active scene (program output)
- **Set Preview Scene** -- set preview scene (studio mode only)
- **Smart Switcher** -- switch scene with auto-detection of studio/live mode
- **Source Cycling** -- cycle through sources within a scene

### Transition Operations
- **Set Scene Transition** -- change transition type/duration
- **Trigger Transition** -- execute transition (studio mode: preview to program)

### Studio Mode
- **Toggle Studio Mode** -- enable/disable studio mode
- **Studio Mode Switch** -- execute the studio mode transition

### Streaming
- **Start Streaming** -- begin stream output
- **Stop Streaming** -- end stream output
- **Toggle Streaming** -- start/stop stream toggle

### Recording
- **Start Recording** -- begin recording
- **Stop Recording** -- end recording
- **Toggle Recording** -- start/stop recording toggle
- **Pause Recording** -- pause active recording
- **Resume Recording** -- resume paused recording
- **Split Recording** -- split recording into new file (keeps recording)
- **Add Recording Chapter** -- add chapter marker to recording

### Replay Buffer
- **Start Replay Buffer** -- begin capturing replay buffer
- **Stop Replay Buffer** -- stop replay buffer
- **Save Replay Buffer** -- save current replay buffer to file
- **Toggle Replay Buffer** -- start/stop replay buffer toggle

### Source Control
- **Toggle Source Visibility** -- show/hide sources within a scene
- **Set Source Filter** -- enable/disable source filters
- **Take Screenshot** -- capture screenshot of source or output
- **Open Projector** -- open fullscreen or windowed projector for source/scene

### Audio
- **Set Audio Mute** -- mute/unmute audio sources
- **Set Audio Volume** -- adjust source volume (dB or multiplier)
- **Toggle Audio Mute** -- toggle mute state

### Virtual Camera
- **Set Virtual Camera** -- start/stop virtual camera
- **Toggle Virtual Camera** -- start/stop virtual camera toggle

### Profiles and Collections
- **Set Profile** -- switch OBS profile
- **Set Scene Collection** -- switch scene collection

### Other
- **Send Hotkey** -- trigger OBS hotkeys remotely

## Available Feedbacks (10+)
- **Streaming Status** -- on/off with duration and dropped frame count
- **Recording Status** -- on/off with duration; includes pause state indicator
- **Recording Paused** -- true when recording is active but paused
- **Current Scene** -- active scene name (program output)
- **Preview Scene** -- active preview scene (studio mode)
- **Source Visibility** -- visible/hidden per source
- **Audio Muted** -- per source mute state
- **Audio Level** -- per source volume meter
- **Studio Mode Active** -- whether studio mode is enabled
- **Replay Buffer Active** -- whether replay buffer is capturing
- **Profile Active** -- true when specific profile is loaded
- **Scene Collection Active** -- true when specific collection is loaded
- **Connection Status** -- connected/disconnected

## Available Variables (35+)

### Scene Info
| Variable | Description |
|----------|-------------|
| `$(obs:scene_name)` | Current active scene name |
| `$(obs:preview_scene)` | Current preview scene (studio mode) |
| `$(obs:scene_collection)` | Active scene collection name |
| `$(obs:profile)` | Active profile name |

### Streaming
| Variable | Description |
|----------|-------------|
| `$(obs:streaming)` | Streaming status (true/false) |
| `$(obs:stream_timecode)` | Stream uptime (HH:MM:SS) |
| `$(obs:stream_duration)` | Stream duration in seconds |
| `$(obs:kbits_per_sec)` | Current stream bitrate |
| `$(obs:total_stream_time)` | Total stream time in seconds |

### Recording
| Variable | Description |
|----------|-------------|
| `$(obs:recording)` | Recording status (true/false) |
| `$(obs:record_timecode)` | Recording duration (HH:MM:SS) |
| `$(obs:record_paused)` | Recording paused status (true/false) |
| `$(obs:record_file_name)` | Current recording file name |

### Performance
| Variable | Description |
|----------|-------------|
| `$(obs:fps)` | Current frames per second |
| `$(obs:cpu_usage)` | CPU usage percentage |
| `$(obs:memory_usage)` | Memory usage in MB |
| `$(obs:free_disk_space)` | Available disk space |
| `$(obs:render_missed_frames)` | Missed frames (rendering lag) |
| `$(obs:render_total_frames)` | Total rendered frames |
| `$(obs:output_skipped_frames)` | Skipped frames (encoding lag) |
| `$(obs:output_total_frames)` | Total output frames |
| `$(obs:average_frame_time)` | Average frame render time (ms) |

### Media Source
| Variable | Description |
|----------|-------------|
| `$(obs:media_time_elapsed)` | Elapsed time of media source |
| `$(obs:media_time_remaining)` | Remaining time of media source |
| `$(obs:media_duration)` | Total duration of media source |
| `$(obs:media_status)` | Playback status (playing/paused/stopped) |

### Replay Buffer
| Variable | Description |
|----------|-------------|
| `$(obs:replay_buffer_active)` | Replay buffer status (true/false) |
| `$(obs:replay_buffer_path)` | Last saved replay buffer file path |

**50+ presets available** covering scene switches, streaming/recording toggles, audio controls, and source visibility toggles.

## Common Button Patterns
```yaml
# Scene switch with tally (green when active)
- type: button
  text: "CAM 1"
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
  text: "STREAM"
  color: "#CC0000"
  actions:
    down:
      - action: obs:toggle_streaming
  feedbacks:
    - type: obs:streaming
      style:
        bgcolor: "#CC0000"
        text: "LIVE\n$(obs:stream_timecode)"

# Recording with pause/resume multi-step control
- type: button
  text: "REC"
  color: "#666666"
  steps:
    - # Step 1: Ready to record
      style:
        text: "REC\n録画"
        bgcolor: "#666666"
      actions:
        down:
          - action: obs:start_recording

    - # Step 2: Recording -- press to pause, hold to stop
      style:
        text: "● REC\n$(obs:record_timecode)"
        bgcolor: "#CC0000"
      actions:
        down:
          - action: obs:pause_recording
        long_press:
          - action: obs:stop_recording
          - action: companion:step_set
            options: { step: 1 }
      feedbacks:
        - type: obs:recording_paused
          style:
            bgcolor: "#CCCC00"
            text: "PAUSED\n$(obs:record_timecode)"

    - # Step 3: Paused -- press to resume, hold to stop
      style:
        text: "PAUSED\n$(obs:record_timecode)"
        bgcolor: "#CCCC00"
      actions:
        down:
          - action: obs:resume_recording
        long_press:
          - action: obs:stop_recording
          - action: companion:step_set
            options: { step: 1 }

# Replay buffer save with confirmation flash
- type: button
  text: "REPLAY\nSave"
  color: "#0066CC"
  actions:
    down:
      - action: obs:save_replay_buffer
  feedbacks:
    - type: obs:replay_buffer_active
      style:
        bgcolor: "#0066CC"
        text: "REPLAY\n● Active"

# Performance monitoring display
- type: button
  text: "$(obs:fps) FPS\n$(obs:cpu_usage)% CPU"
  color: "#333333"
  actions:
    down: []
  feedbacks:
    - type: obs:connected
      style:
        bgcolor: "#333333"
        text: "$(obs:fps) FPS\n$(obs:cpu_usage)%\n$(obs:free_disk_space)"
    - type: obs:streaming
      style:
        bgcolor: "#003300"
        text: "$(obs:fps) FPS\n$(obs:kbits_per_sec)kb/s\n$(obs:cpu_usage)%"

# Profile switching with active indicator
- type: button
  text: "Worship"
  color: "#666666"
  actions:
    down:
      - action: obs:set_profile
        options:
          profile: "Worship Service"
  feedbacks:
    - type: obs:profile_active
      options:
        profile: "Worship Service"
      style:
        bgcolor: "#0066CC"
        text: "Worship\n● Active"

# Studio mode toggle with preview/program awareness
- type: button
  text: "Studio\nMode"
  color: "#666666"
  actions:
    down:
      - action: obs:toggle_studio_mode
  feedbacks:
    - type: obs:studio_mode_active
      style:
        bgcolor: "#9900CC"
        text: "Studio\n● ON"

# Screenshot capture with long-press for source-specific
- type: button
  text: "Screenshot"
  color: "#666666"
  actions:
    down:
      - action: obs:take_screenshot
        options:
          source: ""  # Empty = full output
    long_press:
      - action: obs:take_screenshot
        options:
          source: "Camera 1"
```

## Troubleshooting
- **Can't connect** -- verify WebSocket server is enabled in OBS Tools menu
- **Password rejected** -- check OBS WebSocket settings for the auth token
- **Scene switch lag** -- normal, OBS processes transitions asynchronously
- **Audio controls not working** -- source names must match exactly (case-sensitive)
- **Recording pause not working** -- requires OBS 28+; verify recording is active first
- **Replay buffer save fails** -- replay buffer must be started first; check disk space
- **Studio mode transition fails** -- verify studio mode is enabled before triggering transition
