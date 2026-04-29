# OBS Studio — System Doc

> **Status: NOT YET CONFIGURED — placeholder.**
>
> No OBS connections currently exist in `apps/companion/config/connections.yaml`. This doc captures the planned shape so that wiring it up later is mechanical.

OBS Studio is planned for **streaming and recording** at both YIBC and Saitama. Saitama may eventually hand recording off to a hardware Blackmagic recorder (see [`blackmagic-recorder.md`](blackmagic-recorder.md)) but OBS will likely remain in the streaming path either way.

## Module

- Package: `obs-studio` (the canonical Companion-bundled module)
- Version: TBD — confirm when the connection is added
- Protocol: obs-websocket v5

> Verify the exact module ID once the first connection is added. The bundled name has historically been `obs-studio` (formerly `obs`); confirm against the live module list.

## Planned Connection Config

```yaml
# YIBC (planned)
- id: obs_yibc
  module: "obs-studio"
  label: "OBS (YIBC)"
  enabled: true
  config:
    host: "TBD"
    port: 4455
    password: "TBD"

# Saitama (planned)
- id: obs_saitama
  module: "obs-studio"
  label: "OBS (Saitama)"
  enabled: true
  config:
    host: "TBD"
    port: 4455
    password: "TBD"
```

`4455` is the obs-websocket v5 default. Older v4 used `4444`.

## Common Actions (obs-websocket v5)

| Action | `definitionId` | Notes |
|---|---|---|
| Toggle streaming | `toggle_streaming` | Start/stop stream |
| Start streaming | `start_streaming` | |
| Stop streaming | `stop_streaming` | |
| Toggle recording | `toggle_recording` | Start/stop record |
| Start recording | `start_recording` | |
| Stop recording | `stop_recording` | |
| Set current scene | `set_current_scene` | option: `scene` (name) |
| Set preview scene | `set_preview_scene` | studio mode only |
| Trigger transition | `do_transition` | |
| Toggle source visibility | `toggle_source_visibility` | per-scene source |

Confirm exact IDs against the live module — the module has changed action IDs across major versions.

## Common Scenes

Standard scene set we plan to drive from the Stream Decks:

| Scene | Purpose |
|---|---|
| `Main` | Default program |
| `Camera` | Full-screen camera |
| `Slides` | Full-screen ProPresenter capture |
| `PiP` | Camera + slides picture-in-picture |
| `Wide` | Wide congregation shot |
| `Intro` | Pre-service loop |
| `Outro` | Post-service loop |
| `BRB` | Be-right-back / interstitial |

## Variables

| Variable | Description |
|---|---|
| `streaming` | Currently streaming (bool) |
| `recording` | Currently recording (bool) |
| `scene_active` | Active program scene name |
| `scene_preview` | Preview scene (studio mode) |
| `stream_timecode` | Stream elapsed time |
| `rec_timecode` | Recording elapsed time |
| `cpu_usage` | OBS CPU% (if exposed) |

## Common Feedbacks

| Feedback | Use |
|---|---|
| `streaming_active` | Light up STREAM button red |
| `recording_active` | Light up RECORD button red |
| `scene_active` | Highlight currently-on-program scene tile |
| `connected` | Show connection status |

## TODO

- [ ] Confirm OBS host/IP for YIBC streaming machine
- [ ] Confirm OBS host/IP for Saitama streaming machine
- [ ] Set obs-websocket passwords and store in connection config
- [ ] Verify exact module package name and version against the deployed Companion
- [ ] Define final scene names per location (some may diverge from the standard set above)
- [ ] Add YAML pages: `pages/yibc/<deck>-pageNN-stream.yaml`, `pages/saitama/xl-page04-stream.yaml` (skeleton already exists for Saitama)

## Related

- Module reference: [`../integrations/obs-studio.md`](../integrations/obs-studio.md)
- Saitama stream page skeleton: `apps/companion/config/pages/saitama/xl-page04-stream.yaml`
- ATEM (Saitama routing): [`atem.md`](atem.md)
