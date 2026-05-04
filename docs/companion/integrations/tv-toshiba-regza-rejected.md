# TV — Toshiba REGZA 32S20 (rejected for automation)

## Status

**Rejected 2026-05-04.** Not suitable for unattended startup/shutdown
sequences. Test hardware retired.

## Hardware

| Field | Value |
|---|---|
| Manufacturer | Toshiba (東芝映像ソリューション) |
| Model | REGZA 32S20 |
| Year | 2017 (firmware build `tm15jp20170619`) |
| Region | Japan |
| Serial | 89R05214 / EC21E50C4598 |
| Wired MAC | EC:21:E5:0C:45:98 |
| Default state | DHCP, all defaults — no settings adjustment needed post-reset |

## What worked

- **HDMI-CEC over Pi 5 `/dev/cec0`** (vc4_hdmi adapter, kernel CEC API). Pi
  registers as Playback Device 1, TV at logical address 0.
- **CEC menu navigation** via `cec-ctl` from a privileged pod with
  `/dev/cec0` mounted: `setup-menu` (0x0a) opens 設定, DOWN/UP/SELECT
  navigates, EXIT (0x0d) backs out.
- **Factory reset via CEC** — full menu walk: 設定 → 初期設定 →
  設定の初期化 → confirm はい. Cleared user settings (TV did not
  re-launch a fresh-out-of-box wizard, just dumped to defaults).
- **CEC `standby` (0x36)** powers TV off cleanly. LED red.
- **CEC `image-view-on` (0x04)** powers TV on **only when in soft
  standby** (i.e. previously off'd via CEC standby). LED green.
- **CEC `give-device-power-status` (0x8f)** reliably reports `on` /
  `standby` / `to-standby`. Useful for closed-loop checks.

## What did not work

- **CEC wake from cold standby.** After the TV is hard-off'd via the
  TV body power button or cord pull, the TV's CEC subsystem stays alive
  enough to *answer* `give-device-power-status` (returns `standby`) but
  it ignores `image-view-on`. TV will not wake without a manual side
  button press. **This is the disqualifying behavior.**
- **CEC `set-stream-path`** (input switch). Sent for HDMI 1 / HDMI 2 —
  TV transmitted the message but display did not change inputs. 32S20
  apparently filters routing-control messages from a Playback Device.
- **CEC `root-menu`** (0x09) — TV ignores. Use `setup-menu` (0x0a) for
  the 設定 panel instead.
- **Network-based remote control** — none. The 32S20 exposes only:
  - `:7681/tcp` HTTP, all paths return 404
  - `:7685/tcp` opens then terminates (likely waiting for proprietary
    handshake)
  - `:20000/tcp` UPnP/DLNA Intel SDK 1.2 — DLNA media playback only,
    not remote control. All direct GETs return 500.

  No REGZA Apps Connect support on this entry-level model. No
  smartphone remote app. No documented Companion module.

- **Wake-on-LAN** — not tested but unlikely to work; the TV has no
  "Network Standby" / WoL setting in the menu and cold-state CEC
  liveness suggests deep sleep kills networking.

## Operator-facing diagnostic surfaces

- Hardware buttons accessible without remote: 電源 (power), +/− (volume,
  also acts as up/down in modal mode), 機能切換 (function/input switch
  cycle). The function-switch button cycles between modes
  (Input list → Channel select → Broadcast type) — does NOT reach
  the 設定 menu. Without the IR remote there is no way to access TV
  settings using only the body buttons.

## Implications for future TVs

To support unattended startup/shutdown via Companion the candidate TV
must satisfy at least one of:

1. **Native IP control API** + Companion module — LG WebOS, Samsung
   Tizen, Sony Bravia, Roku TV (each has a maintained
   `companion-module-*-tv`). Power, input, volume all over network.
2. **CEC wake from cold state** — many newer Toshiba/TCL/Hisense
   panels honor `image-view-on` post-cord-pull. Verify by powering
   off via the IR remote (not the body button) plus cord pull, then
   sending CEC wake.
3. **Always-on power** with managed standby + WoL — older
   commercial-grade displays.

CEC is fine as a fallback control surface but cannot be the primary
power-on path for a TV that's been hard-off'd.

## Investigation script

Reproducible test harness for any future TV evaluation:

```sh
# 1. Find on network — ping sweep before vs after plugging in TV
$K exec netshoot -- nmap -sn 192.168.x.0/24 -PE --max-retries 1 -T4 -oG -

# 2. Fingerprint
$K exec netshoot -- nmap -p- --min-rate 2000 -T4 <tv-ip>
$K exec netshoot -- curl -s -D - http://<tv-ip>:<port>/  # banner each open port

# 3. CEC adapter on Pi — register playback device + scan
cec-ctl -d /dev/cec0 --playback
cec-ctl -d /dev/cec0 --show-topology

# 4. Test power lifecycle
cec-ctl -d /dev/cec0 --to 0 --standby                          # off
cec-ctl -d /dev/cec0 --to 0 --image-view-on                    # warm wake
# ... operator hard-offs TV via remote/body button ...
cec-ctl -d /dev/cec0 --to 0 --image-view-on                    # cold wake
cec-ctl -d /dev/cec0 --to 0 --give-device-power-status         # confirm

# 5. Test input routing (HDMI 1 = 1.0.0.0, HDMI 2 = 2.0.0.0, ...)
cec-ctl -d /dev/cec0 --to 0 --set-stream-path phys-addr=2.0.0.0
```

Key acceptance bar: **cold-state CEC wake or native IP API**. Skip
the model if neither.
