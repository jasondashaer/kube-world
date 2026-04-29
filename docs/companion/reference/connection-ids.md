# Connection ID Reference

All Companion connection IDs in use, their underlying modules, host configuration, and which pages reference them.

Source: `apps/companion/config/connections.yaml`

## Naming convention

For modules that have one instance per location (mixer, PP), the connection ID uses a location suffix:

```
<base>_<location>      e.g. yamaha_yibc, yamaha_saitama
```

For modules that have only one instance globally (PTZ at YIBC, HA), no suffix:

```
<base>                 e.g. ptz, homeassistant
```

The connection `id` is the stable token used in YAML page actions (`yamaha_yibc:MIXER_Current/...`). The `label` is the human-readable name shown in the Companion UI. Variable references must use the **sanitized label** (spaces and parens become underscores) — see [variables.md](variables.md).

Both YIBC and Saitama connections are defined simultaneously. At each Pi location, only the local connections will succeed; the others show as disconnected. This is expected and acceptable — status indicators on the dashboards reflect the actual connection state.

---

## Active connections

### `homeassistant`

| Field | Value |
|-------|-------|
| Module | `homeassistant-server` |
| Label | `Home Assistant` |
| Host | `http://home-assistant.home-assistant.svc.cluster.local:8123` |
| Token | (placeholder — `access_token: ""`) |
| Location | YIBC (and reachable from any cluster node) |
| Used by | (none yet — reserved for HA automation buttons) |

Note: this is the in-cluster Service DNS, not a LAN IP. Companion runs with `hostNetwork: true` but the K3s service mesh resolves cluster DNS regardless. Validate with `kubectl run -n companion --rm -it test --image=curlimages/curl -- curl http://home-assistant.home-assistant.svc.cluster.local:8123`.

### `ptz`

| Field | Value |
|-------|-------|
| Module | `ptzoptics-visca` |
| Label | `PTZ Camera` |
| Host | `192.168.1.113` |
| Port | `5678` |
| Protocol | `tcp` |
| Location | YIBC only (no PTZ at Saitama yet) |
| Used by | Pages 20, 21 |

### `yamaha_yibc`

| Field | Value |
|-------|-------|
| Module | `yamaha-rcp` |
| Label | `Yamaha TF5 (YIBC)` |
| Host | `192.168.1.54` |
| Model | `TF` |
| Required flag | `isFirstInit: true` (do not omit) |
| Location | YIBC |
| Used by | Pages 30, 40 (status feedback only — actions on 41 use saitama variant), implicitly 41's MUTE feedback patterns |

Wait — page 30 and triggers reference `yamaha_yibc`. Page 40, 41 reference `yamaha_saitama`. Confirmed.

### `yamaha_saitama`

| Field | Value |
|-------|-------|
| Module | `yamaha-rcp` |
| Label | `Yamaha TF1 (Saitama)` |
| Host | `192.168.10.30` |
| Model | `TF` |
| Required flag | `isFirstInit: true` |
| Location | Saitama |
| Used by | Pages 40, 41 |

### `propresenter_yibc`

| Field | Value |
|-------|-------|
| Module | `renewedvision-propresenter` |
| Label | `ProPresenter (YIBC)` |
| Host | `192.168.1.2` |
| Port | `1025` |
| Pass | `YIBC` |
| `use_sd` | `yes` |
| `sdpass` | (empty) |
| `sendPresentationCurrentMsgs` | `disabled` (mandatory for stability) |
| `timerPolling` | `enabled` |
| Location | YIBC |
| Used by | Page 30 |

### `propresenter_saitama`

| Field | Value |
|-------|-------|
| Module | `renewedvision-propresenter` |
| Label | `ProPresenter (Saitama)` |
| Host | `192.168.68.55` |
| Port | `53678` |
| Pass | `test1234` |
| `use_sd` | `yes` |
| `sdpass` | (empty) |
| `sendPresentationCurrentMsgs` | `disabled` |
| `timerPolling` | `enabled` |
| Location | Saitama |
| Used by | Pages 40, 42 |

---

## Connections referenced but not yet defined

These appear in page YAML but have no entry in `connections.yaml`. Buttons referencing them will be no-ops or show disconnected feedback states.

| Connection ID | Module (likely) | Used by |
|---------------|-----------------|---------|
| `obs` | `bitfocus-obs-websocket` | Pages 30, 40, 43 |
| `atem` | `bmd-atem` | Pages 40, 43 |

To add: see [guides/add-new-system.md](../guides/add-new-system.md).

---

## Connection ID summary table

| Connection ID | Module | Host | Location | Pages |
|---------------|--------|------|----------|-------|
| `homeassistant` | `homeassistant-server` | cluster DNS | YIBC | (none) |
| `ptz` | `ptzoptics-visca` | 192.168.1.113 | YIBC | 20, 21 |
| `yamaha_yibc` | `yamaha-rcp` | 192.168.1.54 | YIBC | 30 |
| `yamaha_saitama` | `yamaha-rcp` | 192.168.10.30 | Saitama | 40, 41 |
| `propresenter_yibc` | `renewedvision-propresenter` | 192.168.1.2:1025 | YIBC | 30 |
| `propresenter_saitama` | `renewedvision-propresenter` | 192.168.68.55:53678 | Saitama | 40, 42 |
| `obs` (TBD) | (TBD) | — | both | 30, 40, 43 |
| `atem` (TBD) | (TBD) | — | Saitama | 40, 43 |

---

## Cross-references

- Source YAML: `apps/companion/config/connections.yaml`
- Action IDs by module: [action-ids.md](action-ids.md)
- Variables exposed by each connection: [variables.md](variables.md)
- Adding a new connection: [guides/add-new-system.md](../guides/add-new-system.md)
