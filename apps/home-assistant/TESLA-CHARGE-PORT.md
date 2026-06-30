# Tesla charge-cable release (Tessie)

Lets the Tesla's charge cable be unplugged on demand from the HA dashboard,
**but only when it's safe**. Scope is the **charge-cable lock ONLY** — actuator
is `lock.unlock` on the Tessie charge-cable-lock entity; no drive, doors, trunk,
cabin, or door cover. Tessie handles the Tesla Fleet API signing, so there is no
custom signing proxy in this cluster.

Vehicle: **Driveway Model Y** (Tessie display name → entity slug
`driveway_model_y`).

GitOps-managed pieces live in [config.yaml](config.yaml):
- `input_boolean.tesla_unlatch_enabled` — hard kill switch (ON = release allowed).
- `script.tesla_charge_port_unlatch` — the gated release, in the `scripts.yaml`
  ConfigMap key.

## Safety model (all gates fail-closed)

The script unlocks the cable only if **every** check passes; otherwise it shows a
plain-language notification and does nothing. Unknown/unavailable state always
aborts (never unlocks).

| Gate | Pass condition | Message on fail |
|------|----------------|-----------------|
| Kill switch | `input_boolean.tesla_unlatch_enabled` = on | "Charge-cable release is turned off." |
| Home | `device_tracker.driveway_model_y_location` ∈ {home, Home} | "Tesla isn't home." |
| Plugged in | `binary_sensor.driveway_model_y_charge_cable` = on | "No cable plugged in." |
| Not in gear | `sensor.driveway_model_y_shift_state` ∉ {d,r,n,D,R,N} | "Tesla isn't parked." |
| Battery | `sensor.driveway_model_y_battery_level` ≥ 50 | "Tesla battery too low — leave it plugged in." |
| Idempotent | `lock...charge_cable_lock` ≠ unlocked | "Charge cable already unlocked." |
| (all pass) | → `lock.unlock` on `lock.driveway_model_y_charge_cable_lock` | "Charge cable unlocked — you can unplug now." |

The 50% battery floor keeps the car plugged in until it's charged enough; below
that, the button refuses and tells the user why. The "plugged in" gate doubles as
a parked-at-charger proof (a plugged car can't be driving), and the not-in-gear
gate is belt-and-suspenders against a stale `shift_state`.

## Setup status — complete (GitOps)

Token + Tessie integration are added (token lives in HA `.storage` on the PVC,
NOT git). Entity IDs in the script match the live `driveway_model_y` entities.

The **buttons are GitOps too** — two YAML-mode dashboards ship in
[config.yaml](config.yaml), copied to the PVC by the init container and registered
via the `lovelace:` block. Default storage-mode dashboards are left untouched
(`lovelace.mode: storage`).

| Dashboard | ConfigMap key | Sidebar item | Who sees it | Contents |
|-----------|---------------|--------------|-------------|----------|
| User | `tesla-dashboard.yaml` | "Tesla" | **all** logged-in users | release button + **read-only** status (plugged, battery, gear, location) |
| Admin | `tesla-admin-dashboard.yaml` | "Tesla (Admin)" | **admins only** (`require_admin: true`) | release button + full status incl. **controls** (kill switch, cable lock) |

This is the two-tier split: a non-admin (e.g. the `kube-world-users` group) can
**only** trigger the gated release and view the read-only gate inputs. The two
interactive controls — the kill switch (`input_boolean`) and the cable lock
(`lock`, which an entities card renders as a direct unlock toggle) — are
admin-only, so a non-admin can never bypass the gates or disable the feature.
The Tessie **integration config itself** (Settings → Devices & Services) is already
admin-only by HA's native RBAC — non-admins can't open or reconfigure it.

Nothing left to click in the UI — just push and the sidebar pages appear.

## Reproducibility caveat

If the cluster is wiped and the HA PVC lost, regenerate the Tessie token and
re-add the integration — that state is not in git. The script, kill switch, and
gates ARE in git and restore automatically.

## Testing

With the car home + plugged in + ≥50%: press the button → notification "you can
unplug now" and the cable lock releases. Below 50%: press → "battery too low" and
nothing happens. Logbook records every attempt and its outcome.
