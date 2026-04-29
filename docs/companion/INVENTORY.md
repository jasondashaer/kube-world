# Companion Hardware Inventory

Flat reference of every device the Companion subsystem talks to, across both locations. See also: [ARCHITECTURE.md](ARCHITECTURE.md), [PIPELINE.md](PIPELINE.md), [STATUS.md](STATUS.md).

## 1. Compute

### pi-edge-1 (the Companion host)

| Field | Value |
|-------|-------|
| **Model** | Raspberry Pi 5, 16GB RAM |
| **Storage** | NVMe (boot) + microSD fallback |
| **OS** | Raspberry Pi OS arm64 + K3s `v1.34.6+k3s1` |
| **Role** | Edge K3s cluster — runs Companion, Home Assistant, Node-RED, Mosquitto, Zigbee2MQTT, ESPHome, code-server, InfluxDB |
| **LAN IP (YIBC)** | DHCP-assigned, `192.168.1.x` range (matches mixer/PTZ subnet) |
| **LAN IP (Saitama)** | DHCP-assigned, `192.168.10.x` range (matches mixer subnet) |
| **Tailscale IP** | from `tailab53c1.ts.net` tailnet — stable across networks |
| **Tailscale FQDN** | `pi-edge-1.tailab53c1.ts.net` |
| **K3s API** | `:6443` on host |
| **Companion ports (hostNetwork)** | `8000/tcp` (HTTP/tRPC), `16622/tcp` (Stream Deck Network/Satellite) |
| **External URL** | `https://companion.edge1.kubew.dev` (via cluster Traefik + cert-manager + ExternalDNS) |

### pi-central (NOT a Companion host — listed for context)

| Field | Value |
|-------|-------|
| **Model** | Raspberry Pi 5, 16GB RAM, 1TB NVMe |
| **Role** | Central K3s — Karmada control plane, Rancher, Zitadel, GitLab CE, Flux |
| **Relevance to Companion** | Hosts the Flux + Karmada that propagate Companion manifests to pi-edge-1. Does not run Companion itself. |

## 2. YIBC (Yokohama International Baptist Church)

LAN: `192.168.1.0/24`. Pi-edge-1 attaches to this LAN when on-site at YIBC.

### YIBC AV Devices

| Device | Model | IP:Port | Auth | Companion Connection ID |
|--------|-------|---------|------|-------------------------|
| Audio Mixer | Yamaha TF5 | `192.168.1.54:49280` (RCP) | none | `yamaha_yibc` |
| ProPresenter | ProPresenter 7 v18.4 | `192.168.1.2:1025` | pass=`YIBC` | `propresenter_yibc` |
| PTZ Camera | PTZOptics VISCA-over-IP | `192.168.1.113:5678` (TCP) | none | `ptz` |

### YIBC Stream Decks

| Serial | Group ID | Name | Type | Address | Startup Page | Page File |
|--------|----------|------|------|---------|--------------|-----------|
| `A00WA5241MWHZB` | `streamdeck:A00WA5241MWHZB` | Stream Deck+ | SD+ (8 buttons + 4 LCD + 4 encoders) | `192.168.1.42` | 20 | `pages/yibc/plus-page01-ptz.yaml`, `plus-page02-dpad.yaml` |
| `A00SA5432NCLFZ` | `streamdeck:A00SA5432NCLFZ` | Stream Deck MK2 | SD MK2 (15 buttons, 5x3) | `192.168.1.43` | 30 | `pages/yibc/mk2-page01-ops.yaml`, `mk2-page02-segments.yaml` |
| (third deck — see STATUS) | - | (TBD) | - | - | - | - |

### YIBC Yamaha TF5 Channel Map

Standard YIBC service mix. RCP fader scale: `-32768` = -infinity, `0` = 0dB, `1000` = +10dB (100 units = 1dB). Mute: `Val: 1` = ON (unmuted), `Val: 0` = MUTED.

| Channel | RCP X | Source | Notes |
|---------|------:|--------|-------|
| ST Master | 1 | Stereo bus | `MIXER_Current/St/Fader/Level` |
| MIX 17 (front-fill aux) | 17 | Aux | Maintains -6dB offset to ST during fades |
| InCh 1-8 | 1-8 | Mics/inputs | `MIXER_Current/InCh/Fader/On` for mute |
| (full per-channel map TBD — confirm from console) | | | |

### YIBC PTZ Presets

PTZOptics VISCA. Action: `ptz:recallPreset`, options: `{isText: false, presetAsNumber: N}`.

| Preset # | Name | Use |
|---------:|------|-----|
| 0 | Cross | Cross-stage / pulpit framing (default `preset_name_0`) |
| 1 | Wide | Full-stage wide (default `preset_name_1`) |
| (2+) | TBD | Confirm from camera memory |

VISCA speed scale: 1-24. Default `ptz_speed` = 12.

### YIBC ProPresenter

| Field | Value |
|-------|-------|
| Version | ProPresenter 7 v18.4 |
| Network port | 1025 |
| Stage Display password | (`use_sd: yes`, `sdpass: ""`) |
| Critical config | `sendPresentationCurrentMsgs: "disabled"` (Pro7 stability), `timerPolling: "enabled"` (timer variables) |

## 3. Saitama

LAN: `192.168.10.0/24` (mixer subnet) + `192.168.68.0/24` (ProPresenter subnet — separate VLAN). Pi-edge-1 attaches when on-site at Saitama. ProPresenter runs on a different subnet and is reachable via L3 routing on the Saitama network.

### Saitama AV Devices

| Device | Model | IP:Port | Auth | Companion Connection ID |
|--------|-------|---------|------|-------------------------|
| Audio Mixer | Yamaha TF1 | `192.168.10.30:49280` (RCP) | none | `yamaha_saitama` |
| ProPresenter | ProPresenter 7 v21.3 | `192.168.68.55:53678` | pass=`test1234` | `propresenter_saitama` |

No PTZ camera at Saitama.

### Saitama Stream Decks

| Serial | Group ID | Name | Type | Address | Startup Page | Page Files |
|--------|----------|------|------|---------|--------------|------------|
| `A00NA53835A5F1` | `streamdeck:A00NA53835A5F1` | Stream Deck XL | SD XL (32 buttons, 8x4) | `192.168.1.41` | 40 | `pages/saitama/xl-page01-home.yaml`, `xl-page02-audio.yaml`, `xl-page03-slides.yaml`, `xl-page04-stream.yaml`, `xl-page05-segments.yaml` |

NOTE: XL address shown as `192.168.1.41` — this was set when the deck was last on the YIBC LAN. When physically deployed at Saitama, this address will be in the `192.168.10.x` range. The `address` field in `surfaces.yaml` is informational; the deck itself initiates connection via its onboard IP setup screen.

### Saitama Yamaha TF1 Channel Map

| Channel | RCP X | Source | Notes |
|---------|------:|--------|-------|
| ST Master | 1 | Stereo bus | |
| (Saitama-specific channel map TBD — confirm from console) | | | |

### Saitama ProPresenter

| Field | Value |
|-------|-------|
| Version | ProPresenter 7 v21.3 (newer than YIBC's 18.4) |
| Network port | 53678 (non-default) |
| Password | `test1234` |
| Stage Display password | (`use_sd: yes`, `sdpass: ""`) |
| Critical config | `sendPresentationCurrentMsgs: "disabled"`, `timerPolling: "enabled"` |

## 4. OBS / Streaming / ATEM / Spotify (placeholder hosts)

Defined in `connections.yaml`. Hosts and credentials are placeholders — fill in via Companion UI or by editing `connections.yaml` after live install.

| Connection ID | Module | Target | Auth |
|---------------|--------|--------|------|
| `obs_yibc` | `bitfocus-obs-websocket` | `192.168.1.50:4455` (placeholder) | password TBD |
| `obs_saitama` | `bitfocus-obs-websocket` | `192.168.10.50:4455` (placeholder) | password TBD |
| `atem_saitama` | `bmd-atem` | `192.168.10.40` (placeholder) | none |
| `spotify_yibc` | `bitfocus-spotify-premium` | OAuth (no host) | clientId/clientSecret + UI OAuth |
| `spotify_saitama` | `bitfocus-spotify-premium` | OAuth (no host) | clientId/clientSecret + UI OAuth (separate account from YIBC) |

OBS scenes referenced in `triggers.yaml`:

| Scene Name | Used By Trigger | Purpose |
|------------|-----------------|---------|
| `Intro` | "YIBC Pre-Service: Intro graphic at 10s" | Bumper before service (YIBC) |
| `Camera` | "YIBC Pre-Service: Go live at countdown end" | Live camera scene |
| `Outro` | end-of-service close flow | Closing bumper |

ATEM input numbers used by Saitama triggers (placeholders — verify against site setup): input 4 = Graphic, input 1 = Camera.

Spotify is used by the close flow (`SVC CLOSE 1` on MK2 page 30 row 2 col 2) to start a post-service playlist. Premium account required for playback control. OAuth completes in the Companion UI; tokens are not stored in git.

## 5. Internal / Cluster Connections

| Connection ID | Module | Target | Reachable From |
|---------------|--------|--------|----------------|
| `homeassistant` | `homeassistant-server` | `http://home-assistant.home-assistant.svc.cluster.local:8123` | Always (cluster DNS via `ClusterFirstWithHostNet`) |

Access token: empty by default — set via Long-Lived Access Token from HA when integration is exercised. Currently used as a placeholder.

## 6. Network Summary

| Network | CIDR | Devices |
|---------|------|---------|
| YIBC LAN | `192.168.1.0/24` | pi-edge-1 (when on-site), TF5, ProPresenter (YIBC), PTZ, all 3 YIBC Stream Decks |
| Saitama mixer LAN | `192.168.10.0/24` | pi-edge-1 (when on-site), TF1 |
| Saitama PP LAN | `192.168.68.0/24` | ProPresenter (Saitama) |
| Cluster pod network | `10.42.0.0/16` (K3s default) | not used by Companion (hostNetwork) |
| Cluster service network | `10.43.0.0/16` (K3s default) | Companion ClusterIP service for Job-internal access |
| Tailscale tailnet | `tailab53c1.ts.net` | pi-central, pi-edge-1, dev workstation |

## 7. Custom Variables (state)

Defined in `variables.yaml`. Persistent variables survive Companion restarts.

| Name | Default | Persist | Purpose |
|------|---------|--------:|---------|
| `startup_phase` | `Idle` | no | System boot phase indicator |
| `service_mode` | `Off` | yes | Service flow state machine: `Off`, `Ready`, `Pre-Service`, `Live`, `Closing`, `Starting` |
| `all_connected` | `false` | no | Aggregate connection health |
| `pre_duck_level` | `0` | no | Stored ST master level before audio duck |
| `duck_active` | `0` | no | 0=normal, 1=ducked |
| `ptz_speed` | `12` | no | VISCA pan/tilt speed (1-24) |
| `preset_sel_0` | `0` | no | D-Pad encoder 0 selected preset |
| `preset_sel_1` | `1` | no | D-Pad encoder 1 selected preset |
| `preset_name_0` | `Cross` | no | Display name for preset_sel_0 |
| `preset_name_1` | `Wide` | no | Display name for preset_sel_1 |
| `service_armed` | `0` | no | Master gate for ARM-gated pre-service trigger chain |
| `record_bus_idx` | `21` | yes | TF Mix bus number used for live stream/record feed (TBD per console) |
| `closing_target_db_units` | `-300` | yes | Master fader target (-3dB) for close-flow talking-volume |
| `pre_close_master_level` | `0` | no | Snapshot of master before close (for restore) |
| `pre_close_mix_level` | `0` | no | Snapshot of record bus before close |
| `close_stage` | `Idle` | no | Close-flow stage marker: `Idle` → `Closing-Underscore` → `Stopped` |

## 8. Pages Reference

| Page # | Location | Surface | File | Doc |
|------:|----------|---------|------|-----|
| 20 | YIBC | Stream Deck+ | `pages/yibc/plus-page01-ptz.yaml` | [yibc-plus-20-ptz.md](pages/yibc-plus-20-ptz.md) |
| 21 | YIBC | Stream Deck+ (subpage) | `pages/yibc/plus-page02-dpad.yaml` | [yibc-plus-21-dpad.md](pages/yibc-plus-21-dpad.md) |
| 30 | YIBC | Stream Deck MK2 | `pages/yibc/mk2-page01-ops.yaml` | [yibc-mk2-30-ops.md](pages/yibc-mk2-30-ops.md) |
| 31 | YIBC | Stream Deck MK2 (segments) | `pages/yibc/mk2-page02-segments.yaml` | [yibc-mk2-31-segments.md](pages/yibc-mk2-31-segments.md) |
| 40 | Saitama | Stream Deck XL | `pages/saitama/xl-page01-home.yaml` | [saitama-xl-40-home.md](pages/saitama-xl-40-home.md) |
| 41 | Saitama | Stream Deck XL (audio) | `pages/saitama/xl-page02-audio.yaml` | [saitama-xl-41-audio.md](pages/saitama-xl-41-audio.md) |
| 42 | Saitama | Stream Deck XL (slides) | `pages/saitama/xl-page03-slides.yaml` | [saitama-xl-42-prop.md](pages/saitama-xl-42-prop.md) |
| 43 | Saitama | Stream Deck XL (stream) | `pages/saitama/xl-page04-stream.yaml` | [saitama-xl-43-stream.md](pages/saitama-xl-43-stream.md) |
| 44 | Saitama | Stream Deck XL (segments) | `pages/saitama/xl-page05-segments.yaml` | [saitama-xl-44-segments.md](pages/saitama-xl-44-segments.md) |

## 9. Scripts

| Path | Purpose |
|------|---------|
| `apps/companion/scripts/companion-deploy.py` | YAML → tRPC config importer. Auto-runs in-cluster via Job/Deployment init container on every ConfigMap hash change. Never run manually against a live deck — Karmada will revert UI edits |
| `apps/companion/scripts/companion-sync.sh` | Helper to round-trip Companion's exported `.companionconfig` blob against the YAML source |
| `apps/companion/scripts/mixer-state-deploy.py` | **Operator-run** RCP push from `apps/companion/config/scenes/<location>/*.yaml` to TF mixer **Bank B** (canonical baselines). Supports `--dry-run` and `--apply`. Bank B → Bank A copy is a separate deliberate step on the front panel — see [scene-strategy.md](guides/scene-strategy.md) |

## 10. Scene Library (declarative mixer state)

Per-location YAML scene definitions consumed by `mixer-state-deploy.py`. Each YAML describes a complete Bank B target state (channel labels, fader levels, mute, HA gain/phantom, send levels, mix bus levels, DCAs).

| Path | Scenes | Notes |
|------|--------|-------|
| `apps/companion/config/scenes/yibc/01-announcements.yaml` | Bank B scene 1 | Room mics + announcer mic |
| `apps/companion/config/scenes/yibc/02-worship.yaml` | Bank B scene 2 | Vocal + instrument layer |
| `apps/companion/config/scenes/yibc/03-sermon.yaml` | Bank B scene 3 | Pulpit + lapel only |
| `apps/companion/config/scenes/yibc/04-greeting.yaml` | Bank B scene 4 | Ambient room mics |
| `apps/companion/config/scenes/saitama/03-sermon.yaml` | Bank B scene 3 | Saitama-specific (Pastor=11, Worship=1, Guitar=4, Keys=6, Media=14). Other Saitama scenes pending |

Bank A (engineer-edited working scenes) is **not** in git — it lives on the mixer and is owned by the sound engineer. See the hybrid Bank A / Bank B model in [scene-strategy.md](guides/scene-strategy.md).

## 11. Cross-References

- System architecture: [ARCHITECTURE.md](ARCHITECTURE.md)
- GitOps pipeline: [PIPELINE.md](PIPELINE.md)
- Live state: [STATUS.md](STATUS.md)
- Module action ID reference: `docs/companion/integrations/module-action-reference.md`
- PTZ camera details: `docs/companion/integrations/ptz-camera.md`
- Yamaha TF details: `docs/companion/integrations/yamaha-tf.md`
- Yamaha RCP namespace + value scaling: `docs/companion/reference/yamaha-rcp-namespace.md`
- Scene strategy (Bank A / Bank B): `docs/companion/guides/scene-strategy.md`
