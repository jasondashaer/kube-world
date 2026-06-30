# Tesla charge-port release (Tessie)

Lets the Tesla's charge cable be unplugged on demand from the HA dashboard,
**but only when it's safe**. Scope is charge-port ONLY — no drive, doors, cabin,
or anything else. Tessie handles the Tesla Fleet API signing, so there is no
custom signing proxy in this cluster.

GitOps-managed pieces live in [config.yaml](config.yaml):
- `input_boolean.tesla_unlatch_enabled` — hard kill switch (ON = release allowed).
- `script.tesla_charge_port_unlatch` — the gated release, in the `scripts.yaml`
  ConfigMap key.

## Safety model (all gates fail-closed)

The script releases the latch only if **every** check passes; otherwise it shows
a plain-language notification and does nothing. Unknown/unavailable state always
aborts (never opens).

| Gate | Pass condition | Message on fail |
|------|----------------|-----------------|
| Kill switch | `input_boolean.tesla_unlatch_enabled` = on | "Charge-port release is turned off." |
| Home | `device_tracker.tesla_location` = home | "Tesla isn't home." |
| Parked | `sensor.tesla_shift_state` = P | "Tesla isn't parked." |
| Battery | `sensor.tesla_battery_level` ≥ 50 | "Tesla battery too low — leave it plugged in." |
| Idempotent | port not already open | "Charge port already unlocked." |
| (all pass) | → `cover.open_cover` | "Charge port unlocked — you can unplug now." |

The 50% battery floor keeps the car plugged in until it's charged enough; below
that, the button refuses and tells the user why.

## One-time setup (manual, not GitOps)

The Tessie account token is NOT stored in git — it lives in HA `.storage` on the
PVC via the integration's config flow.

1. **Generate a Tessie token:** Tessie app/site → Settings → Developer / API →
   create an access token. (Lifetime sub covers API command access.)
2. **Add the integration:** HA → Settings → Devices & Services → Add Integration
   → **Tessie** → paste the token. It auto-discovers the vehicle(s).
3. **Note the entity prefix.** Tessie names entities after the car's display
   name, e.g. a car named "Model 3" → `sensor.model_3_battery_level`. The script
   ships with the placeholder prefix **`tesla`**.
4. **Rename the placeholders** in [config.yaml](config.yaml) `scripts.yaml` to
   match — replace each `tesla` entity prefix:
   - `device_tracker.tesla_location`
   - `sensor.tesla_shift_state`
   - `sensor.tesla_battery_level`
   - `cover.tesla_charge_port`
   Then commit + push (Flux → Karmada → edge1 → HA reload).
5. **Add the dashboard button** (storage-mode dashboard, added in the UI):

   ```yaml
   show_name: true
   show_icon: true
   type: button
   name: Release Charge Port
   icon: mdi:ev-plug-tesla
   tap_action:
     action: perform-action
     perform_action: script.tesla_charge_port_unlatch
   ```
   (Older HA: `action: call-service` / `service: script.tesla_charge_port_unlatch`.)

   Optionally add an entities card with `input_boolean.tesla_unlatch_enabled` so
   the kill switch is visible.

## Reproducibility caveat

If the cluster is wiped and the HA PVC lost, redo steps 1–2 (token + integration)
— that state is not in git. The script, kill switch, and gates ARE in git and
restore automatically.

## Testing

After setup, with the car home + parked + ≥50%: press the button → notification
"you can unplug now" and the charge port releases. Below 50%: press → "battery
too low" and nothing happens. Logbook records every attempt and its outcome.
