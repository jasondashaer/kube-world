# ProPresenter — System Doc

Slide / lyric / media presentation system used at both YIBC and Saitama. Each location runs a different Pro7 version on a different network address; Companion talks to both via the same module with two parallel connections.

For the full module API (every action, feedback, variable) see [`../integrations/propresenter.md`](../integrations/propresenter.md).

| Field | YIBC | Saitama |
|---|---|---|
| ProPresenter version | Pro7 **v18.4** | Pro7 **v21.3** |
| Host | `192.168.1.2` | `192.168.68.55` |
| Port | `1025` | `53678` |
| Network password | `YIBC` | `test1234` |
| Stage app | enabled, password `""` | enabled, no password |
| Connection ID | `propresenter_yibc` | `propresenter_saitama` |
| Label | `ProPresenter (YIBC)` | `ProPresenter (Saitama)` |

## Module

- Package: `renewedvision-propresenter`
- Version: **3.0.2** (the "classic" line — supports both Pro6 and Pro7)
- Protocol: ProPresenter Network Link (TCP) + Stage Display protocol

> The newer `propresenter` (Pro7-only) module exists, but the classic 3.x is what's deployed because it has the broadest action set and is what the configs target.

## Connection Config

```yaml
- id: propresenter_yibc            # or propresenter_saitama
  module: "renewedvision-propresenter"
  label: "ProPresenter (YIBC)"     # or "ProPresenter (Saitama)"
  enabled: true
  config:
    host: "192.168.1.2"            # YIBC; Saitama: 192.168.68.55
    port: "1025"                   # YIBC; Saitama: "53678"  — STRING, not int
    pass: "YIBC"                   # YIBC; Saitama: "test1234"
    use_sd: "yes"                  # enable Stage Display feed
    sdpass: ""                     # both: empty
    sendPresentationCurrentMsgs: "disabled"   # CRITICAL — see below
    timerPolling: "enabled"        # required for timer/clock variables
```

### Field reference

| Field | Type | Notes |
|---|---|---|
| `host` | string | IP or hostname of the ProPresenter machine |
| `port` | **string** | Yes, string. Pro7 default is the value shown in PP > Preferences > Network |
| `pass` | string | Network Link password (PP > Preferences > Network > Password) |
| `use_sd` | `"yes"` / `"no"` | Stage Display protocol — gives access to timers, current/next slide text |
| `sdpass` | string | Stage app password (empty when stage app has no password) |
| `sendPresentationCurrentMsgs` | `"enabled"` / `"disabled"` | **MUST be `"disabled"` on Pro7** |
| `timerPolling` | `"enabled"` / `"disabled"` | Required for `*_timer*` variables |

### `sendPresentationCurrentMsgs` — read this

On **Pro7**, leaving this `"enabled"` (or omitting it) causes the Network Link connection to drop repeatedly — typically every few seconds. The module sends a "give me the current presentation" request, Pro7 fails to answer cleanly, the socket dies, and Companion reconnects. Symptom: Stream Deck buttons go unresponsive in waves; the Companion log shows constant connect/disconnect.

**Always set `sendPresentationCurrentMsgs: "disabled"` for Pro7.** Pro6 tolerates either.

## Action IDs

| Action | `definitionId` | Notes |
|---|---|---|
| Next (within slide deck) | `next` | Goes to the next slide of the current presentation |
| Last (within slide deck) | `last` | Previous slide |
| Slide number | `slideNumber` | Jump to slide N |
| Clear all | `clearall` | Clear every layer |
| Clear slide | `clearslide` | Clear slide layer only |
| Clear to logo | `cleartologo` | Clear and show logo |
| Clock start | `clockStart` | Start a clock/timer |
| Clock stop | `clockStop` | Stop |
| Clock reset | `clockReset` | Reset to initial value |
| Set Pro7 look | `pro7SetLook` | Option `pro7LookUUID` |
| Trigger Pro7 macro | `pro7TriggerMacro` | Macro by name |
| Audio play/pause | `audioPlayPause` | Toggle audio bin playback |

### `next` vs. "GO"

A common point of confusion:

| Concept | What it does | Action |
|---|---|---|
| **Next slide** | Advance one slide within the currently-active presentation | `next` |
| **GO** (advance the playlist cue) | Trigger the next cue in the playlist — could be a slide, a media item, or a macro | use `slideNumber` / cue trigger actions; classic module has limited GO support |

If you want "spacebar in PP" behaviour, `next` is what you want most of the time.

### Pro7 Looks

`pro7SetLook` requires the **UUID** of the look, not its name:

```yaml
- type: "action"
  definitionId: "pro7SetLook"
  options:
    pro7LookUUID: "8B2E...-..."
```

UUIDs are **dynamic** — populated by the module after it connects to ProPresenter and reads the look list. In the Companion UI they appear as a dropdown; in YAML you have to pin the UUID once you know it. Re-creating a Look in PP changes its UUID.

## Variables

(Module prefix is the connection label normalised, e.g. `ProPresenter (YIBC)` → `ProPresenter`. Both connections share the same prefix; that's a known limitation of two parallel connections from the same module.)

| Variable | Description |
|---|---|
| `connection_status` | connected / disconnected |
| `current_slide` | Active slide index in current presentation |
| `total_slides` | Slide count of current presentation |
| `presentation_name` | Active presentation file name |
| `video_countdown_timer` | Countdown for the current video |
| `watched_clock_current_time` | Current value of the watched clock/timer |

`timerPolling: "enabled"` is required for any `*_timer*` / `*_clock*` variable to update.

## Stage Display

Both locations have Stage Display enabled (`use_sd: "yes"`). This gives:

- Live timer / clock values
- Current and next slide text
- Stage layout switching (via SD actions)

It is **optional**. Without it, slide control still works but most timer feedback goes silent. Recommended on for both locations — already configured.

## Known Issues

- **Pro7 instability** — see `sendPresentationCurrentMsgs` above.
- **Look UUIDs are dynamic** — after recreating a Look, update the YAML.
- **Same module prefix for two connections** — variables from `propresenter_yibc` and `propresenter_saitama` collide in the variable namespace. Mitigated by the fact that only one connection is reachable at a time (whichever LAN the Pi is on).

## Related

- Full module reference: [`../integrations/propresenter.md`](../integrations/propresenter.md)
- Connection source: `apps/companion/config/connections.yaml`
- Pages: `apps/companion/config/pages/yibc/plus-page01-ptz.yaml`, `pages/yibc/mk2-page01-ops.yaml`, `pages/saitama/xl-page03-slides.yaml`
