# PTZ Camera — System Doc

Network-controlled pan/tilt/zoom camera at YIBC. Driven via VISCA over TCP. Saitama has no PTZ camera (cameras at Saitama are fixed and routed through the ATEM).

For the full module action surface and generic VISCA reference, see [`../integrations/ptz-camera.md`](../integrations/ptz-camera.md).

| Field | Value |
|---|---|
| Location | YIBC only |
| Module | `ptzoptics-visca` |
| Module version | **3.5.0** |
| Connection ID | `ptz` |
| Label | `PTZ Camera` |
| Host | `192.168.1.113` |
| Port | `5678` |
| Protocol | TCP |
| Pages that use it | Plus PTZ (page 01), Plus D-pad (page 02) |

## Connection Config

```yaml
- id: ptz
  module: "ptzoptics-visca"
  label: "PTZ Camera"
  enabled: true
  config:
    host: "192.168.1.113"
    port: 5678
    protocol: "tcp"
```

VISCA over TCP/IP. The camera must have VISCA control enabled in its OSD/web UI; PTZOptics-style cameras default to this on port 5678.

## Action IDs

The `ptzoptics-visca` module uses **short** definitionIds. These are the verified, in-use IDs:

### Pan / Tilt

| Action | `definitionId` | Options |
|---|---|---|
| Pan left | `left` | — |
| Pan right | `right` | — |
| Tilt up | `up` | — |
| Tilt down | `down` | — |
| Stop movement | `stop` | — |
| Home | `home` | — |

### Zoom

| Action | `definitionId` | Options |
|---|---|---|
| Zoom in (tele) | `zoomI` | — |
| Zoom out (wide) | `zoomO` | — |
| Zoom stop | `zoomS` | — |

### Focus

| Action | `definitionId` | Options |
|---|---|---|
| Focus near | `focusN` | — |
| Focus far | `focusF` | — |
| Focus stop | `focusS` | — |
| Focus mode toggle | `focusM` | — |

### Presets

| Action | `definitionId` | Options |
|---|---|---|
| Recall preset | `recallPreset` | `{ isText: false, presetAsNumber: N }` |
| Save preset | `setPreset` | `{ isText: false, presetAsNumber: N }` |

`isText: false` is **required** — without it the module treats the preset arg as a string template and the recall fails silently.

### Speed

| Action | `definitionId` | Options |
|---|---|---|
| Set P/T speed | `ptSpeedSet` | `{ speed: 1..24 }` |
| Speed up | `ptSpeedU` | — |
| Speed down | `ptSpeedD` | — |

`speed` range is **1 (slowest) to 24 (fastest)** — the value maps directly to the VISCA pan/tilt speed byte.

### System

| Action | `definitionId` | Options |
|---|---|---|
| Power | `power` | state |
| Custom VISCA | `custom` | `{ custom: "81 01 ..." }` (hex bytes) |

## Preset Map

Live preset assignments at YIBC are documented in [`../locations/yibc.md`](../locations/yibc.md). Common allocation pattern:

| Preset | Use |
|---|---|
| 0 | Wide / home |
| 1 | Pulpit close-up |
| 2 | Worship leader |
| 3 | Keys/piano |
| 4 | Choir wide |
| 5+ | Service-specific |

## Encoder Behaviour — Move + Wait + Stop

Stream Deck+ rotary encoders in Companion fire one action per detent of rotation. With a continuous-motion VISCA action (`left`, `right`, `up`, `down`), a single detent would start the camera moving and never stop it. The fix is a **move → wait → stop** sequence per detent:

```yaml
rotate_left:
  - type: "action"
    definitionId: "left"
  - type: "action"
    definitionId: "wait"
    options:
      time: "10 + (24 - 1) * 15"     # speed-scaled wait
  - type: "action"
    definitionId: "stop"
```

### Wait formula

```
wait_ms = 10 + (speed - 1) * 15
```

Where `speed` is the value sent to `ptSpeedSet`. Sample table:

| Speed | Wait (ms) | Notes |
|---|---|---|
| 1 | 10 | barely moves |
| 4 | 55 | fine framing |
| 8 | 115 | normal |
| 16 | 235 | fast reposition |
| 24 | 355 | max — only off-air |

Tune the constants if the camera over- or under-shoots. The `15` slope is empirical for a typical PTZOptics-style camera.

### Speed selection

`ptSpeedSet` takes `speed: 1..24` directly — no remapping. Encoders typically set a Companion variable (`internal:ptz_speed`) on press, and the wait formula reads it via expression.

## Known Issues

- **Zoom doesn't respond to brief move+stop.** With pan/tilt the move+wait+stop pattern works at any speed. With **zoom**, very short movements (wait < ~80 ms) get swallowed — the camera ignores the movement command. Fix: use **press-and-hold** buttons for zoom (`zoomI` on `down`, `zoomS` on `up`) instead of encoder detents. The Plus D-pad page (`plus-page02-dpad.yaml`) does this.
- **Camera sometimes ignores rapid alternating direction commands.** Letting the previous `stop` complete before sending the next direction helps; that's why the wait-before-stop matters.
- **Network changes break VISCA.** The camera holds the TCP connection open. If the Pi reboots or rejoins the network, you may need to reconnect — Companion does this automatically, but the camera firmware occasionally needs a power cycle if the half-open socket lingers.

## Related

- Full module reference: [`../integrations/ptz-camera.md`](../integrations/ptz-camera.md)
- YIBC preset map: [`../locations/yibc.md`](../locations/yibc.md)
- Pages: `apps/companion/config/pages/yibc/plus-page01-ptz.yaml`, `pages/yibc/plus-page02-dpad.yaml`
