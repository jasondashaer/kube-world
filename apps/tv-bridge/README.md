# tv-bridge

Tiny HTTP wrapper around `adb` that gives Companion (or anything that
speaks HTTP) reliable Android-TV control without the gaps in Companion's
`android-tv` module.

**Why this exists:** Companion's `android-tv` module talks Google's
Android TV Remote v2 protocol on ports 6466/6467. That protocol
implements remote-key + power, but its `power_off` action silently no-ops
on at least one Mediatek-based Philips/KTC firmware when the
`PassthroughPlayerActivity` (HDMI input view) has focus. It also has no
direct HDMI-input switch action. ADB shell key events handle both
cases reliably, so we expose them over a tiny HTTP API and let
Companion call this via the `bitfocus-generic-http` module.

## Endpoints

| Method | Path                | Action                                       |
|-------:|:--------------------|:---------------------------------------------|
| POST   | `/tv/wake`          | `KEYCODE_WAKEUP` — force on                  |
| POST   | `/tv/sleep`         | `KEYCODE_SLEEP` — force off                  |
| POST   | `/tv/power-toggle`  | `KEYCODE_POWER`                              |
| POST   | `/tv/key/<KEYCODE>` | arbitrary keyevent (e.g. `KEYCODE_HOME`)     |
| POST   | `/tv/input/<id>`    | input switch — `home`, `hdmi1`, `hdmi2`, …   |
| GET    | `/tv/state`         | JSON: wakefulness + topResumedActivity       |
| GET    | `/healthz`          | 200 if adb device is reachable               |

`/tv/input/<id>` launches the TIF passthrough URI for that input; the
friendly ids (`hdmi1`, `hdmi2`, `hdmi3`) map to `HW1`, `HW2`, `HW3` per
the Mediatek default. Override with the env `INPUT_TVINPUT` or pass a
raw `HW0`/`HW1`/… in the URL if your firmware differs.

## Two deployment modes

### k3s (current YIBC edge1, Kubernetes-managed)

Build + push the image, then apply the manifest:

```sh
docker build -t ghcr.io/jasondashaer/tv-bridge:latest apps/tv-bridge
docker push ghcr.io/jasondashaer/tv-bridge:latest
kubectl apply -k apps/tv-bridge/k8s/
```

Pod runs with `hostNetwork: true` so adb can reach the TV on the host
LAN, and binds `127.0.0.1:9990` so it's only reachable to other
host-network pods on the same node. Companion (also `hostNetwork: true`)
calls `http://127.0.0.1:9990/tv/wake` etc.

### Vanilla Pi (Saitama-style, no k3s)

```sh
cd apps/tv-bridge/vanilla
sudo ./install.sh 192.168.10.20:5555     # <-- TV's IP:5555
```

This installs `android-tools-adb` + `python3`, drops `bridge.py` under
`/opt/tv-bridge/`, writes `/etc/default/tv-bridge` with `TV_HOST`, and
enables `tv-bridge.service`. Companion (running on the same Pi) calls
`http://127.0.0.1:9990/tv/wake` via generic-http.

## First-time pairing (one-shot, both modes)

ADB-over-WiFi pairing is interactive — the bridge can't do it
unattended. Do this once per TV; the resulting key persists in
`$ANDROID_HOME/.android/` (PVC for k3s, `/var/lib/tv-bridge/.android`
for vanilla).

1. On TV: Settings → System → Developer options → enable **Wireless
   debugging** → tap **Pair device with pairing code**. TV displays
   `IP:PORT` + 6-char code.
2. Run pair from the bridge's user/key store:

   k3s:
   ```sh
   kubectl -n tv-bridge exec -it deploy/tv-bridge -- \
       adb pair <TV_IP>:<PAIR_PORT> <CODE>
   kubectl -n tv-bridge exec -it deploy/tv-bridge -- \
       adb connect <TV_IP>:5555
   ```

   vanilla:
   ```sh
   sudo -u tv-bridge HOME=/var/lib/tv-bridge \
       adb pair <TV_IP>:<PAIR_PORT> <CODE>
   sudo -u tv-bridge HOME=/var/lib/tv-bridge \
       adb connect <TV_IP>:5555
   sudo systemctl restart tv-bridge
   ```
3. Confirm:
   ```sh
   curl -s http://127.0.0.1:9990/healthz       # → {"adb":"ok"}
   curl -s http://127.0.0.1:9990/tv/state      # → wakefulness, etc.
   ```

## Companion integration

Add a generic-http connection in `apps/companion/config/connections.yaml`:

```yaml
  - id: tv_bridge_yibc
    module: "bitfocus-generic-http"
    label: "TV Bridge (YIBC)"
    enabled: true
    config:
      prefix: "http://127.0.0.1:9990"
```

Then on MK2 ops row 1 buttons, fire the bridge:

```yaml
- action: tv_bridge_yibc:post
  options:
    url: "/tv/wake"
    body: ""
    contenttype: "application/json"
```

Power button on Stream Deck = wake. Shutdown = sleep. Service-start
sequence = wake + switch to HDMI 2.

## Network Standby (mandatory)

Configure on the TV: Settings → System → Power → **Network Standby ON**.
Without it the TV's NIC powers off in standby and `KEYCODE_WAKEUP` over
ADB has nothing to talk to. WoL is not used here because Network
Standby keeps adb reachable through soft-off — verified at 5min on the
KTC 6700 series.

## Caveats

- **TIF input ids are firmware-specific.** The default
  `INPUT_TVINPUT=com.mediatek.tvinput/.hdmi.HDMIInputService` and the
  HW0/HW1/HW2 mapping work on Mediatek-based Philips/KTC. Other vendors
  (Sony Bravia / Samsung Tizen / TCL) need different ids — query
  `service call tv_input 1` and watch the `SelectInputActivity`
  Sounds, or just hardcode whatever passthrough URI the launcher uses.
- **ADB key may rotate** if the TV's wireless-debugging session is
  cancelled. Re-pair following the steps above.
- **ADB-over-WiFi requires WiFi.** Wired Ethernet does not expose the
  pairing flow on Android 14. Once paired the actual ADB connect can
  use either link.
