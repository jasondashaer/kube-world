# Companion Status — Living Document

> **This is a LIVING DOCUMENT.** Update whenever the Pi relocates, surfaces are reseated, or connection status changes materially. Do not delete history — append a new dated section if substantive shifts occur.

Last update: **2026-04-29** (segment pages, ARM-gated triggers, scene library, mixer-state-deploy.py)

See also: [ARCHITECTURE.md](ARCHITECTURE.md), [PIPELINE.md](PIPELINE.md), [INVENTORY.md](INVENTORY.md), [CHANGELOG.md](CHANGELOG.md).

## 1. Pi Location

| Field | Value |
|-------|-------|
| **Current site** | TBD (YIBC vs Saitama) |
| **Pi hostname** | `pi-edge-1` |
| **Current LAN IP** | TBD (192.168.1.x at YIBC, 192.168.10.x at Saitama) |
| **Tailscale IP** | stable: `pi-edge-1.tailab53c1.ts.net` |
| **K3s status** | TBD (`systemctl status k3s` on the Pi) |
| **Companion pod status** | TBD (`kubectl get pod -n companion`) |
| **Last GitOps reconcile** | TBD |

## 2. Surfaces Connected

Source of truth: `apps/companion/config/surfaces.yaml`. Live registration state is in Companion's web UI under Surfaces. Decks self-register on first connect to TCP 16622.

| Group ID | Name | Expected IP | Site | Startup Page | Live? |
|----------|------|-------------|------|--------------|-------|
| `streamdeck:A00NA53835A5F1` | Stream Deck XL | `192.168.1.41` (last set; will change at Saitama) | Saitama | 40 | TBD |
| `streamdeck:A00WA5241MWHZB` | Stream Deck+ | `192.168.1.42` | YIBC | 20 | TBD |
| `streamdeck:A00SA5432NCLFZ` | Stream Deck MK2 | `192.168.1.43` | YIBC | 30 | TBD |

## 3. Connection Statuses

By design, the connections matching the **other** location will always show disconnected. See [ARCHITECTURE.md §4](ARCHITECTURE.md#4-connection-model-parallel-per-location-pattern).

| Connection ID | Module | Target | Expected Status (when at YIBC) | Expected Status (when at Saitama) | Live |
|---------------|--------|--------|--------------------------------|-----------------------------------|------|
| `homeassistant` | `homeassistant-server` | cluster DNS | OK | OK | TBD |
| `ptz` | `ptzoptics-visca` | 192.168.1.113 | OK | DISCONNECTED | TBD |
| `yamaha_yibc` | `yamaha-rcp` | 192.168.1.54 | OK | DISCONNECTED | TBD |
| `propresenter_yibc` | `renewedvision-propresenter` | 192.168.1.2:1025 | OK | DISCONNECTED | TBD |
| `obs_yibc` | `bitfocus-obs-websocket` | 192.168.1.50:4455 (placeholder) | TBD | DISCONNECTED | TBD |
| `spotify_yibc` | `bitfocus-spotify-premium` | OAuth (no host) | TBD (UI OAuth pending) | DISCONNECTED | TBD |
| `yamaha_saitama` | `yamaha-rcp` | 192.168.10.30 | DISCONNECTED | OK | TBD |
| `propresenter_saitama` | `renewedvision-propresenter` | 192.168.68.55:53678 | DISCONNECTED | OK | TBD |
| `obs_saitama` | `bitfocus-obs-websocket` | 192.168.10.50:4455 (placeholder) | DISCONNECTED | TBD | TBD |
| `atem_saitama` | `bmd-atem` | 192.168.10.40 (placeholder) | DISCONNECTED | TBD | TBD |
| `spotify_saitama` | `bitfocus-spotify-premium` | OAuth (no host) | DISCONNECTED | TBD (UI OAuth pending) | TBD |

**Placeholder credentials** (filled in via Companion UI after first deploy, not committed to git): OBS host/password (both locations), ATEM host (Saitama), Spotify clientId/clientSecret (both locations) — OAuth completes per-instance via the Companion connection UI on first run.

## 4. Last Successful Import

| Field | Value |
|-------|-------|
| **Git commit hash** | TBD |
| **Date/time** | TBD |
| **Job name** | TBD (`companion-deploy-<checksum>`) |
| **Pages imported** | TBD |
| **Connections imported** | TBD |
| **Triggers imported** | TBD (most disabled by default) |

## 5. Pages, Triggers, Variables, Scripts, Scenes — current build state

### 5.1 Pages (9 total — was 7)

| Page | Name | Location | Device | Source YAML | Doc |
|------|------|----------|--------|-------------|-----|
| 20 | PTZ Encoder Control | YIBC | Plus | `pages/yibc/plus-page01-ptz.yaml` | [yibc-plus-20-ptz.md](pages/yibc-plus-20-ptz.md) |
| 21 | PTZ D-Pad | YIBC | Plus | `pages/yibc/plus-page02-dpad.yaml` | [yibc-plus-21-dpad.md](pages/yibc-plus-21-dpad.md) |
| 30 | Ops | YIBC | MK2 | `pages/yibc/mk2-page01-ops.yaml` | [yibc-mk2-30-ops.md](pages/yibc-mk2-30-ops.md) |
| **31** | **Segments** | **YIBC** | **MK2** | **`pages/yibc/mk2-page02-segments.yaml`** | **[yibc-mk2-31-segments.md](pages/yibc-mk2-31-segments.md)** (new) |
| 40 | Home Dashboard | Saitama | XL | `pages/saitama/xl-page01-home.yaml` | [saitama-xl-40-home.md](pages/saitama-xl-40-home.md) |
| 41 | Audio Mixer | Saitama | XL | `pages/saitama/xl-page02-audio.yaml` | [saitama-xl-41-audio.md](pages/saitama-xl-41-audio.md) |
| 42 | ProP | Saitama | XL | `pages/saitama/xl-page03-slides.yaml` | [saitama-xl-42-prop.md](pages/saitama-xl-42-prop.md) |
| 43 | Stream | Saitama | XL | `pages/saitama/xl-page04-stream.yaml` | [saitama-xl-43-stream.md](pages/saitama-xl-43-stream.md) |
| **44** | **Segments** | **Saitama** | **XL** | **`pages/saitama/xl-page05-segments.yaml`** | **[saitama-xl-44-segments.md](pages/saitama-xl-44-segments.md)** (new) |

### 5.2 New buttons on MK2 page 30 (Ops)

| Pos | Label | Notes |
|-----|-------|-------|
| 1/3 | ARM / DISARM | Two-step toggle. Sets `service_armed`, resets + starts PP timer 0. Gates the YIBC pre-service trigger chain |
| 1/4 | status pad | Live `service_mode` + PP video countdown |
| 2/2 | SVC CLOSE 1 | Stage close: snapshot levels, fade music down, start Spotify, fade up to talking-under level |
| 2/3 | SVC CLOSE 2 | Finish close: PP closing graphic → 12s hold → fade record bus to -∞ → stop OBS stream + recording |
| 2/4 | SEGMENTS → | Navigates to page 31 |

### 5.3 Triggers — ARM-gated service-start chains

All ARM-gated triggers are **DISABLED at deploy** by default. Enable per-trigger after walking through live with mixer + OBS connected.

| Trigger | Enabled | Gates on |
|---------|---------|----------|
| `Startup: Set service mode` | true | startup |
| `YIBC Pre-Service: Start stream at 1min` | false | `service_armed=1` AND PP timer = 00:01:00 |
| `YIBC Pre-Service: Intro graphic at 10s` | false | `service_armed=1` AND PP timer = 00:00:10 |
| `YIBC Pre-Service: Go live at countdown end` | false | `service_armed=1` AND PP timer = 00:00:00 (auto-disarms at end) |
| `Saitama Pre-Service: Start stream at 1min` | false | `service_armed=1` AND PP (Saitama) timer = 00:01:00 |
| `Saitama Pre-Service: Intro graphic at 10s` | false | `service_armed=1` AND PP (Saitama) timer = 00:00:10 (ATEM input 4) |
| `Saitama Pre-Service: Go live at countdown end` | false | `service_armed=1` AND PP (Saitama) timer = 00:00:00 (ATEM input 1, auto-disarms) |

### 5.4 New connections (5 placeholders)

| Connection ID | Module | Target | Auth |
|---------------|--------|--------|------|
| `obs_yibc` | `bitfocus-obs-websocket` | 192.168.1.50:4455 | password TBD |
| `obs_saitama` | `bitfocus-obs-websocket` | 192.168.10.50:4455 | password TBD |
| `atem_saitama` | `bmd-atem` | 192.168.10.40 | none |
| `spotify_yibc` | `bitfocus-spotify-premium` | OAuth | clientId/clientSecret + UI OAuth |
| `spotify_saitama` | `bitfocus-spotify-premium` | OAuth | clientId/clientSecret + UI OAuth |

OAuth (Spotify) finishes via the Companion UI per instance — not stored in git.

### 5.5 New variables

| Name | Default | Persist | Purpose |
|------|---------|---------|---------|
| `service_armed` | `0` | no | Master gate for the pre-service trigger chain |
| `record_bus_idx` | `21` | yes | TF Mix bus number used for the live stream/record feed |
| `closing_target_db_units` | `-300` | yes | Master fader target (-3dB) for the close flow's fixed talking-volume |
| `pre_close_master_level` | `0` | no | Snapshot of master before close (for restore) |
| `pre_close_mix_level` | `0` | no | Snapshot of record bus before close |
| `close_stage` | `Idle` | no | Close-flow state: `Idle` → `Closing-Underscore` → `Stopped` |

### 5.6 New tooling

| Path | Purpose |
|------|---------|
| `apps/companion/scripts/mixer-state-deploy.py` | Operator-run RCP push from `apps/companion/config/scenes/<location>/*.yaml` to TF mixer Bank B (canonical baselines). Manual `--apply`, never auto-runs. Bank B → Bank A copy is a separate manual step on the front panel. See [scene-strategy.md](guides/scene-strategy.md) |

### 5.7 New config tree — declarative mixer scenes

Per-location scene definitions feeding `mixer-state-deploy.py`:

| Path | Scenes |
|------|--------|
| `apps/companion/config/scenes/yibc/` | `01-announcements.yaml`, `02-worship.yaml`, `03-sermon.yaml`, `04-greeting.yaml` (4 scenes) |
| `apps/companion/config/scenes/saitama/` | `03-sermon.yaml` (1 scene; the rest pending) |

### 5.8 New documentation

| Path | Purpose |
|------|---------|
| `docs/companion/reference/yamaha-rcp-namespace.md` | RCP address tree, value scaling, Recall Safe semantics |
| `docs/companion/guides/scene-strategy.md` | Hybrid Bank A / Bank B model, workflow, gotchas |
| `docs/companion/pages/yibc-mk2-31-segments.md` | MK2 segments page detail (this release) |
| `docs/companion/pages/saitama-xl-44-segments.md` | XL segments page detail (this release) |

## 6. Known Issues / Outstanding Items

| Item | Status | Notes |
|------|--------|-------|
| Third YIBC Stream Deck not in surfaces.yaml | Open | Confirm serial and add startup page entry |
| Live test (mixer power on with backup loaded) | Pending | Run `mixer-state-deploy.py --dry-run` first; back up TF state before any `--apply`. Power-cycle mixer with known-good Bank A scene loaded |
| Pro7 clock 0 binding | Unverified | Confirm `clockIndex: "0"` is the video countdown timer at both YIBC (PP 18.4) and Saitama (PP 21.3); the variable label sanitization (`ProPresenter__YIBC_:video_countdown_timer`) needs UI confirmation |
| Record bus channel number | Unverified | `record_bus_idx` default is `21`. Confirm with operator which Mix bus is the live stream/record feed at each console |
| OBS host/password (YIBC + Saitama) | Placeholder | Hosts `192.168.1.50` / `192.168.10.50`; passwords blank. Update via UI after install |
| ATEM host (Saitama) | Placeholder | `192.168.10.40` is a guess; confirm at site |
| Spotify OAuth | Pending | clientId/clientSecret blank for both `spotify_yibc` and `spotify_saitama`; complete OAuth in the Companion UI after first connection. Premium account required for playback control |
| Pro7 closing-graphic macro UUID | Placeholder | `PLACEHOLDER_CLOSING_GRAPHIC_MACRO` in CLOSE 2; replace with actual Pro7 macro UUID when authored |
| Spotify playlist URI | Placeholder | `PLACEHOLDER_PLAYLIST_URI` in CLOSE 1; replace with actual playlist URI |
| Service-flow triggers all disabled | Intentional | Per `triggers.yaml` header: enable only after live walkthrough |
| Bank B canonical scenes pushed | Partial | YIBC has 4 scene YAMLs but `mixer-state-deploy.py --apply` not yet run against TF5; Saitama has only `03-sermon.yaml` authored |

## 7. Update Procedure

When updating this file:

1. Edit the section that changed. Don't blank out unrelated sections.
2. Bump the "Last update" date at the top.
3. Append a one-line entry to [CHANGELOG.md](CHANGELOG.md) summarizing the change.
4. Commit with message `docs: companion status — <what changed>`.
5. Push. (No GitOps reconcile triggered — docs aren't deployed.)

## 8. Quick Health Check Commands

```bash
# From dev workstation:
flux get all -A | grep companion
kubectl --context karmada-apiserver get configmap -n companion

# On pi-edge-1:
kubectl get pod,job,configmap -n companion
kubectl logs -n companion deployment/companion --tail=100
kubectl logs -n companion -l job-name -c companion-deploy --tail=200

# Companion HTTP health:
curl -sI https://companion.edge1.kubew.dev/ | head -1
# expect: HTTP/2 200
```
