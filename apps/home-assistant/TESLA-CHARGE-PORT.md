# Tesla charge-cable release + door unlock (Tessie)

Two gated, safety-checked actions from the HA dashboard. Tessie handles the Tesla
Fleet API signing, so there is no custom signing proxy in this cluster.

1. **Charge-cable release** — `lock.unlock` on the Tessie charge-cable-lock
   entity. No drive/trunk/cabin actuation. (Original scope.)
2. **Door unlock** — `lock.unlock` on the whole-car door lock, **auto-re-locked
   after 60s**. Intent: open the driver door to stow the charge adapter, then the
   car secures itself. Tesla has **no per-door command**, so this unlocks all
   doors; a Model Y can't power-open a door either, so "open one door" isn't
   possible — unlock-all + auto-relock is the closest safe equivalent.

Vehicle: **Driveway Model Y** (Tessie display name → entity slug
`driveway_model_y`).

GitOps-managed pieces live in [config.yaml](config.yaml):
- `input_boolean.tesla_unlatch_enabled` — kill switch for cable release.
- `input_boolean.tesla_unlock_doors_enabled` — kill switch for door unlock.
- `script.tesla_charge_port_unlatch` — the gated cable release.
- `script.tesla_unlock_doors` — the gated door unlock (`mode: restart`, 60s
  auto-relock). Both live in the `scripts.yaml` ConfigMap key.

## Door unlock gates (fail-closed)

| Gate | Pass condition | Message on fail |
|------|----------------|-----------------|
| Kill switch | `input_boolean.tesla_unlock_doors_enabled` = on | "Door unlock is turned off." |
| Home | `device_tracker...location` ∈ {home, Home} | "Tesla isn't home." |
| Not in gear | `sensor...shift_state` ∉ {d,r,n,D,R,N} | "Tesla isn't parked." |
| (all pass) | → `lock.unlock` on `lock.driveway_model_y_lock`, wait 60s, `lock.lock` | "Doors unlocked — they will lock again in 1 minute." |

`mode: restart` means a second press cancels the in-flight delay and restarts the
full 60s window. **Caveat:** the auto-relock relies on the script staying alive
for the 60s delay — an HA restart inside that window would skip the relock and the
car would stay unlocked (only ever while parked at home). The **Unlock Doors**
button is on **both** the user and admin dashboards (per request); the kill switch
is admin-only.

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
