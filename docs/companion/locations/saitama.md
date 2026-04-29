# Saitama — Location Spec

Saitama is a secondary location currently in **testing**. A single Stream Deck XL drives full production: ATEM (routing/recording only), OBS streaming, Yamaha TF1 audio, and ProPresenter. Pi-edge-1 is brought on-site temporarily; a permanent install is TODO.

## Network

Three chained routers. Subnets vary by which router each device sits behind. **IPs change between visits** — verify before each session and update `apps/companion/config/` via git.

| Subnet | Router role | Devices typically here |
|---|---|---|
| `192.168.10.0/24` | TF1 mixer router | Yamaha TF1 |
| `192.168.68.0/24` | ProPresenter router | ProPresenter laptop |
| `192.168.1.0/24` | Booth / Stream Deck router | Stream Deck XL, Pi-edge-1 |

Cross-subnet routing is handled by the upstream chained routers. Companion (`hostNetwork: true` on the Pi) reaches all three via the chain. Latency is variable — observed fine for RCP/OSC at typical service tempo.

## Hardware inventory

| Device | Address | Module | Notes |
|---|---|---|---|
| Yamaha TF1 mixer | `192.168.10.30` | `yamaha-rcp` (model `TF`) | RCP/TCP. Same module as YIBC TF5 — single TF model option. |
| ProPresenter 7 v21.3 | `192.168.68.55:53678` | `renewedvision-propresenter` | Password `test1234`. **May need rotation** — temp credential. `sendPresentationCurrentMsgs: disabled` mandatory. |
| Stream Deck XL | `192.168.1.41` (current) | network module | Serial `A00NA53835A5F1`. Page 40. **IP not stable across visits.** |
| ATEM switcher | (model TBC) | `bmd-atem` (future) | **Used for streaming/recording feed routing only — NOT live switching.** Live switching is operator-driven elsewhere. |
| Blackmagic recorder | (future, networked) | TBD | Planned dedicated recorder. |
| Pi-edge-1 | DHCP on `192.168.1.x` | — | Carried in for sessions; permanent placement TBD. |

## TF1 channel map

Saitama-specific channel assignments (differ from YIBC TF5):

| Channel | Source | RCP X | Notes |
|---|---|---|---|
| 11 | Pastor | `X: 11` | Sermon mic. |
| 1 | Worship | `X: 1` | Worship vocal lead. |
| 6 | Keys | `X: 6` | |
| 4 | Guitar | `X: 4` | |
| 14 | Media | `X: 14` | Playback / video audio. |

Use the standard `MIXER_Current/InCh/Fader/On` (mute) and `MIXER_Current/InCh/Fader/Level` (level) RCP addresses with the channel number as `X`.

## What's NOT here

| Excluded | Reason |
|---|---|
| PTZ camera | Not installed at Saitama. PTZ-specific pages/connections are YIBC-only. |
| Home Assistant | Building automation not in scope. |
| Network lighting | Not present. |
| ATEM as live-switcher | ATEM is used for routing/streaming/recording only; live switching is performed by an operator on dedicated gear. |

## Stream Deck assignment

| Surface | Serial | LAN IP | Startup page | Spec |
|---|---|---|---|---|
| Stream Deck XL | `A00NA53835A5F1` | `192.168.1.41` (verify each visit) | 40 (Home) | [stream-deck-xl.md](../devices/stream-deck-xl.md) |

### Page layout

| Page | Name | Purpose |
|---|---|---|
| 40 | Home | Status row + scene/transition + nav. Default. |
| 41 | Audio Mixer (TF1) | Per-channel mute / level adjust / scene recall. |
| 42 | Slides (ProPresenter) | Prev/Next/Go, slide jumps, looks, timer, blank. |
| 43 | Stream / Recording | OBS + ATEM routing, Blackmagic record arm, AudRC. |

Navigation: Home (40) → sub-pages via row-3 buttons; sub-pages → Home via `←Home` at `[3,7]`. PANIC button on page 40 is a 2-step confirm that triggers FTB + master mute.

## Operator workflows

### Setup (each visit)
1. Plug in Pi-edge-1 to booth router. Note assigned IP.
2. Verify Stream Deck XL DHCP IP — update `apps/companion/config/surfaces.yaml` if changed.
3. Verify TF1 (`192.168.10.30`), ProPresenter (`192.168.68.55:53678`), Stream Deck IPs.
4. Commit any IP changes to git → Flux reconciles → Companion re-imports → connections come up.
5. Confirm status row on page 40 shows all green.

### Service
- **Page 40 (Home):** scene cuts (CAM 1/2/3, PC), transitions (AUTO/CUT/FTB), audio mute master, navigate to sub-pages.
- **Page 41 (Audio):** per-channel mute (Pastor/Worship/Choir/Keys/Guitar/Media/FX/Master), trim level (▲/▼), scene recall, 0 dB / -∞ shortcuts.
- **Page 42 (Slides):** ProPresenter advance, slide jumps, looks (Norml/Lyric/Scrpt/Blank), timer.
- **Page 43 (Stream):** start/stop streaming, recording, ATEM routing, Blackmagic record arm.

## Open TODOs

- [ ] **Mixer scenes TBD** — Bank/Slot mappings for TF1 not yet defined (Page 41 references `Scn 1`–`Scn 4` placeholders).
- [ ] **ProPresenter password** — `test1234` is a temp credential; rotate and update `connections.yaml`.
- [ ] **Stream Deck XL IP stability** — set DHCP reservation on booth router, or move to static.
- [ ] **Permanent Pi install** — currently transported per visit; need rack/closet placement, network drop, persistent DHCP reservation, on-site monitoring.
- [ ] **ATEM module choice** — confirm exact ATEM model and configure `bmd-atem` connection.
- [ ] **Blackmagic recorder** — define module + add to connections once unit is selected.
- [ ] **OBS connection** — currently used in pages but not yet defined in `connections.yaml` (uses `obs:` action prefix; needs a real OBS WebSocket connection).
- [ ] **Verify TF1 channel map** with on-site sound op; current map is best-known but unverified.

## Cross-references

- Device: [Stream Deck XL](../devices/stream-deck-xl.md)
- Pages: [`apps/companion/config/pages/saitama/`](../../../apps/companion/config/pages/saitama/)
- Connections: [`apps/companion/config/connections.yaml`](../../../apps/companion/config/connections.yaml) (`yamaha_saitama`, `propresenter_saitama`)
- Sister location: [YIBC](yibc.md)
