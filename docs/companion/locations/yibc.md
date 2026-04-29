# YIBC — Location Spec

YIBC is the active production deployment. Two Stream Decks (Plus + MK2) drive PTZ camera, audio mixing, and ProPresenter advance from the booth.

## Network

Single subnet, single router.

| Item | Value |
|---|---|
| LAN | `192.168.1.0/24` |
| Gateway | `192.168.1.1` (router) |
| DHCP | Router-assigned. Static reservations recommended for booth gear. |
| Pi-edge-1 | DHCP-assigned on `192.168.1.x` when on-site. (Apartment-network testing uses `192.168.0.175` with cross-subnet NAT.) |
| Companion bind | `hostNetwork: true` — Pod uses Pi's LAN IP directly. |

## Hardware inventory

| Device | Address | Module | Notes |
|---|---|---|---|
| Yamaha TF5 mixer | `192.168.1.54` | `yamaha-rcp` (model `TF`) | RCP/TCP. `isFirstInit: true` required to avoid `findRcpCmd undefined` upgrade-script crash. |
| ProPresenter 7 v18.4 | `192.168.1.2:1025` | `renewedvision-propresenter` | Password `YIBC`. `sendPresentationCurrentMsgs: disabled` (mandatory for Pro7 stability). `timerPolling: enabled`. |
| PTZ camera (PTZOptics) | `192.168.1.113:5678` | `ptzoptics-visca` | VISCA-over-TCP. |
| Stream Deck+ | `192.168.1.42` | network module (Elgato outbound TCP) | Serial `A00WA5241MWHZB`. Page 20. |
| Stream Deck MK2 | `192.168.1.43` | network module | Serial `A00SA5432NCLFZ`. Page 30. |
| Home Assistant | `home-assistant.home-assistant.svc.cluster.local:8123` | `homeassistant-server` | In-cluster service; reachable from Pi pod network. (Future use.) |

## PTZ camera presets

Presets stored on the camera itself; Companion recalls by number via `ptz:recallPreset` with `{isText: false, presetAsNumber: N}`. Long-press on Plus preset buttons saves the current pose with `ptz:setPreset`.

| # | Name | Description |
|---|---|---|
| 0 | Cross | Cross / altar view |
| 1 | Wide | Wide congregation shot |
| 2 | Sermon | Speaker close-up |
| 3 | Pulpit | Pulpit framing |
| 4 | Worship | Worship leader |
| 5 | Guitar | Guitarist |
| 6 | Baptism | Baptism area |

VISCA action IDs used: `left`, `right`, `up`, `down`, `home`, `stop`, `zoomI`, `zoomO`, `zoomS`, `recallPreset`, `setPreset`, `ptSpeedU`, `ptSpeedD`, `ptSpeedSet`.

## Audio routing

| Bus | Yamaha RCP address | Notes |
|---|---|---|
| Stereo master | `MIXER_Current/St/Fader/...` (X=1) | Main FOH output. |
| Aux 17 | `MIXER_Current/Mix/Fader/...` (X=17) | Front-fill speakers. Runs at `-6 dB` offset relative to master. |

Fader scale (Yamaha TF): `-32768` = -∞dB, `0` = 0 dB, `1000` = +10 dB. **100 units per dB.** Mute logic: `Val: 1` = on (unmuted), `Val: 0` = muted (inverted from intuition).

### Multi-bus fades

Aux 17 is kept at master `+ (-600)` units throughout fades, preserving the -6 dB offset. The DUCK button on the MK2 (page 30) implements this as 20 stepped commands × 50 ms = 1 s smooth ramp from 0 dB → -20 dB on master and -6 dB → -26 dB on aux 17. See [`pages/yibc/mk2-page01-ops.yaml`](../../../apps/companion/config/pages/yibc/mk2-page01-ops.yaml).

## Mixer scenes

The TF5 stores user scenes in banks; recall via `MIXER_Lib/Bank/Scene/Recall`. **Current state: Bank 1 / Slot A is referenced as a placeholder** — a real scene mapping has not yet been authored. Scene contents and slot assignments are TODO.

| Bank | Slot | Purpose | Status |
|---|---|---|---|
| 1 | A | (placeholder, used by MK2 page) | TODO — define real scene |

## Stream Deck assignments

| Surface | Serial | LAN IP | Startup page | Spec |
|---|---|---|---|---|
| Stream Deck+ | `A00WA5241MWHZB` | `192.168.1.42` | 20 (PTZ encoders) | [stream-deck-plus.md](../devices/stream-deck-plus.md) |
| Stream Deck MK2 | `A00SA5432NCLFZ` | `192.168.1.43` | 30 (Ops) | [stream-deck-mk2.md](../devices/stream-deck-mk2.md) |

### Page layout

- **Page 20** — PTZ encoder control (Plus default). Pan/tilt/speed knobs, preset buttons, zoom. Encoder rotate uses `rotate_left`/`rotate_right` (NOT `rotate_cw`/`rotate_ccw`) at the import layer.
- **Page 21** — PTZ d-pad. Arrow buttons + preset-selector knobs.
- **Page 30** — MK2 ops. Stream/record (OBS), ProPresenter prev/next/clear, master mute, duck.

## Operator workflows

### Service prep (pre-service)
1. Power on TF5, confirm scene 1A recalled (or recall manually pending real scene mapping).
2. Power on PTZ camera; confirm presets 0–6 still match physical positions.
3. Power on ProPresenter laptop, open service stack.
4. Pi-edge-1 boots → Companion comes up via Flux/Karmada → Stream Decks reconnect.

### During service
- **PTZ Plus (page 20):** rotate Pan/Tilt knobs to fine-tune; tap preset buttons to recall; long-press preset to update.
- **MK2 (page 30):**
  - PREV/NEXT advance ProPresenter slides.
  - DUCK fades audio -20 dB during prayer/announcements; press again to UNDUCK.
  - Master Mute is the emergency cut (instant, both stereo + aux 17).

### Long-press preset save
Long-press any preset button on Plus pages 20/21 to write the camera's current pose into that preset slot. Useful when seasonal stage layout shifts.

## Open TODOs

- [ ] Define real Yamaha TF5 scene mappings (Bank/Slot → service phase). Currently only a placeholder reference exists.
- [ ] Add ProPresenter look/macro buttons on MK2 page 30 (currently 4 unused buttons in rows 1–2).
- [ ] Verify Stream Deck IP reservations stick across router reboots; consider DHCP static leases.
- [ ] Wire Home Assistant into ops page (lighting cues, room HVAC) once HA is in scope at YIBC.
- [ ] Document camera preset re-calibration procedure with photos.

## Cross-references

- Devices: [Plus](../devices/stream-deck-plus.md), [MK2](../devices/stream-deck-mk2.md)
- Pages: [`apps/companion/config/pages/yibc/`](../../../apps/companion/config/pages/yibc/)
- Connections: [`apps/companion/config/connections.yaml`](../../../apps/companion/config/connections.yaml) (`yamaha_yibc`, `propresenter_yibc`, `ptz`, `homeassistant`)
- Sister location: [Saitama](saitama.md)
