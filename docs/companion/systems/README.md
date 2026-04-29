# Companion Integrated Systems

Index of every external system the Bitfocus Companion subsystem talks to. Each entry below is a "system" — i.e. a real-world device or service Companion drives — distinct from the per-module references in [`../integrations/`](../integrations/), which document module APIs (action IDs, options, feedbacks) regardless of where they're used.

This directory ties **modules → real deployments**: which mixer is at which church, which ProPresenter version, what IPs, what's actually wired up vs. planned.

## At-a-Glance

| System | Module | YIBC | Saitama | Status | Doc |
|---|---|:-:|:-:|---|---|
| Yamaha TF mixer | `yamaha-rcp` | TF5 | TF1 | Live (both) | [yamaha-tf.md](yamaha-tf.md) |
| ProPresenter 7 | `renewedvision-propresenter` | v18.4 | v21.3 | Live (both) | [propresenter.md](propresenter.md) |
| PTZ camera | `ptzoptics-visca` | yes | — | Live | [ptz-camera.md](ptz-camera.md) |
| OBS Studio | `obs-studio` | planned | planned | Placeholder | [obs-studio.md](obs-studio.md) |
| Blackmagic ATEM | `bmd-atem` | — | planned | Placeholder | [atem.md](atem.md) |
| Home Assistant | `homeassistant-server` | yes | — | Connected, no buttons | [home-assistant.md](home-assistant.md) |
| Blackmagic recorder | `bmd-hyperdeck` (probable) | — | future | Placeholder | [blackmagic-recorder.md](blackmagic-recorder.md) |

## System Summaries

### Yamaha TF mixer — both locations
Digital audio console driven via Yamaha RCP (TCP). YIBC runs a **TF5** (32 channel), Saitama runs a **TF1** (16 channel). Same module, two parallel connections (`yamaha_yibc`, `yamaha_saitama`). Used for fader nudges, mute toggles, scene recall, and software-implemented smooth fades. → [yamaha-tf.md](yamaha-tf.md)

### ProPresenter — both locations
Slide / lyric / video presentation. Two different versions deployed:
- **YIBC**: Pro7 v18.4 at `192.168.1.2:1025`
- **Saitama**: Pro7 v21.3 at `192.168.68.55:53678`

Connection IDs: `propresenter_yibc`, `propresenter_saitama`. Pro7 stability requires `sendPresentationCurrentMsgs: "disabled"`. → [propresenter.md](propresenter.md)

### PTZ camera — YIBC only
PTZOptics-style VISCA camera at `192.168.1.113:5678`. Used for live video framing, preset recall, and encoder-based pan/tilt/zoom on the Stream Deck+. Saitama has no PTZ. → [ptz-camera.md](ptz-camera.md)

### OBS Studio — both planned
Planned for streaming and software recording at both locations. Not yet configured — module connection TBD. → [obs-studio.md](obs-studio.md)

### Blackmagic ATEM — Saitama only (planned)
Hardware switcher used for **streaming routing and recording output**, not as the live program switcher. Not yet configured. → [atem.md](atem.md)

### Home Assistant — YIBC only
Cluster-internal HA reachable at `home-assistant.home-assistant.svc.cluster.local:8123`. Connection is live but no buttons currently bind to it; reserved for future room/lighting control. → [home-assistant.md](home-assistant.md)

### Blackmagic recorder — Saitama future
Will replace OBS-based recording with a hardware HyperDeck (or similar) for reliability. Placeholder only. → [blackmagic-recorder.md](blackmagic-recorder.md)

## Related

- Module API references: [`../integrations/`](../integrations/) — action IDs, option formats, feedbacks
- Connection definitions (source of truth): `apps/companion/config/connections.yaml`
- Per-location specs: [`../locations/`](../locations/)
- Per-page button matrices: [`../pages/`](../pages/)
