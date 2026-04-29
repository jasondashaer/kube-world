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
| `A00SA5432NCLFZ` | `streamdeck:A00SA5432NCLFZ` | Stream Deck MK2 | SD MK2 (15 buttons, 5x3) | `192.168.1.43` | 30 | `pages/yibc/mk2-page01-ops.yaml` |
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
| `A00NA53835A5F1` | `streamdeck:A00NA53835A5F1` | Stream Deck XL | SD XL (32 buttons, 8x4) | `192.168.1.41` | 40 | `pages/saitama/xl-page01-home.yaml`, `xl-page02-audio.yaml`, `xl-page03-slides.yaml`, `xl-page04-stream.yaml` |

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

## 4. OBS / Streaming

OBS scenes referenced in `triggers.yaml`. OBS connection is **not yet defined in connections.yaml** — referenced for future implementation.

| Scene Name | Used By Trigger | Purpose |
|------------|-----------------|---------|
| `Intro` | "Pre-Service: Intro at 10sec" | Bumper before service |
| `Camera` | "Pre-Service: Go live at countdown end" | Live camera scene |
| `Outro` | "End: Outro scene after 10sec" | Closing bumper |

OBS WebSocket connection IDs / ports / passwords TBD when OBS connection is added.

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

## 8. Pages Reference

| Page # | Location | Surface | File |
|------:|----------|---------|------|
| 20 | YIBC | Stream Deck+ | `pages/yibc/plus-page01-ptz.yaml` |
| 21 | YIBC | Stream Deck+ (subpage) | `pages/yibc/plus-page02-dpad.yaml` |
| 30 | YIBC | Stream Deck MK2 | `pages/yibc/mk2-page01-ops.yaml` |
| 40 | Saitama | Stream Deck XL | `pages/saitama/xl-page01-home.yaml` |
| 41 | Saitama | Stream Deck XL (audio) | `pages/saitama/xl-page02-audio.yaml` |
| 42 | Saitama | Stream Deck XL (slides) | `pages/saitama/xl-page03-slides.yaml` |
| 43 | Saitama | Stream Deck XL (stream) | `pages/saitama/xl-page04-stream.yaml` |

## 9. Cross-References

- System architecture: [ARCHITECTURE.md](ARCHITECTURE.md)
- GitOps pipeline: [PIPELINE.md](PIPELINE.md)
- Live state: [STATUS.md](STATUS.md)
- Module action ID reference: `docs/companion/integrations/module-action-reference.md`
- PTZ camera details: `docs/companion/integrations/ptz-camera.md`
- Yamaha TF details: `docs/companion/integrations/yamaha-tf.md`
