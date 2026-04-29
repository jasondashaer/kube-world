# Home Assistant — System Doc

Cluster-internal Home Assistant instance, reachable from Companion at the in-cluster service URL. **YIBC only** — no HA at Saitama.

| Field | Value |
|---|---|
| Location | YIBC only |
| Module | `homeassistant-server` |
| Connection ID | `homeassistant` |
| Label | `Home Assistant` |
| Host (URL) | `http://home-assistant.home-assistant.svc.cluster.local:8123` |
| Access token | (empty in repo — set out-of-band when wired up) |
| Status | Connection live; **no buttons currently use it** |

## Connection Config

```yaml
- id: homeassistant
  module: "homeassistant-server"
  label: "Home Assistant"
  enabled: true
  config:
    host: "http://home-assistant.home-assistant.svc.cluster.local:8123"
    access_token: ""
```

A few notes on this config:

- The URL is the **Kubernetes service DNS name** for the HA pod running in the same cluster as Companion. Because Companion runs with `hostNetwork: true` on `pi-edge-1`, it can resolve cluster service names via the node's resolver chain (k3s coredns).
- `access_token` is a **long-lived access token** generated from inside HA → Profile → Long-Lived Access Tokens. It's intentionally left empty in the YAML in this repo; rotate / inject via a sealed secret or via direct config edit on the Pi when you set this up properly.
- The Companion module talks to HA over the REST + WebSocket APIs; both run on the same `8123` port.

## Current Use

**None.** The connection exists so Companion can see HA, but there are no buttons today that actually trigger HA actions. The integration is intentionally pre-wired for when the YIBC HA setup is mature enough to control from a Stream Deck.

## Future Plans (YIBC)

Once HA at YIBC has stable entities, likely first-pass integrations:

- **Sanctuary lights toggle** — house lights on/off, stage lights on/off, programmable scenes
- **Room presets** — "service starting", "rehearsal", "post-service", combining lights + HVAC
- **Door sensor / motion indication** — informational feedback on Stream Deck
- **HVAC quick-toggle** — pre-service warm-up

When implementing, prefer scene-based actions over per-entity actions on the Stream Deck — fewer buttons, more reliable state.

## Common Actions (`homeassistant-server` module)

For when buttons get wired up:

| Action | Notes |
|---|---|
| Call service | Generic `service.domain` call with arbitrary payload |
| Turn on / off | Per-entity light/switch/scene control |
| Toggle | Toggle binary state |
| Trigger automation | Run a named automation |
| Activate scene | Activate an HA scene |

Confirm exact `definitionId`s against the module reference when adding the first button.

## Variables

The module exposes per-entity state as variables once entities are subscribed. Pattern:

```
$(homeassistant:<entity_id>_state)
$(homeassistant:<entity_id>_attribute_<attr>)
```

## Known Issues

- **Token rotation discipline** — when the HA admin rotates the long-lived token, Companion silently disconnects. There is no Stream Deck warning today; add a `connected` feedback to a status page when you wire HA in.
- **In-cluster URL** — uses cluster DNS, which only works as long as Companion is scheduled on a Pi inside the cluster (it always is by design). If Companion is ever moved off-cluster, switch to the HA ingress URL.

## Related

- Full module reference: [`../integrations/home-assistant.md`](../integrations/home-assistant.md)
- HA app spec in this repo: `apps/home-assistant/`
- Connection source: `apps/companion/config/connections.yaml`
