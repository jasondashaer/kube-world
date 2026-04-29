# Guide: Add a New System (Connection)

Add a new module connection (mixer, switcher, OBS instance, lighting, etc.) to Companion.

## Prerequisites

- The system is reachable from the Pi running Companion (LAN routable, firewall holes, credentials).
- A Companion module exists for the system (search [bitfocus/companion-module-*](https://github.com/bitfocus) on GitHub).
- You know the module's connection ID format from the module's `companion/manifest.json` `id` field.

---

## Step 1 — Identify required config fields

Look up the module's required connection config. Two ways:

1. **From a running pod**:

   ```bash
   ssh pi-edge-1 "kubectl exec -n companion deploy/companion -- cat /companion/modules/<module-name>/companion/manifest.json"
   ```
   Look at the `connectionConfig` schema.

2. **From the module source on GitHub**: e.g. `companion-module-bitfocus-obs-websocket/companion/manifest.json`.

Note all required fields and their types (host, port, password, etc.).

## Step 2 — Add to `connections.yaml`

Append an entry following the naming convention (see [connection-ids.md](../reference/connection-ids.md#naming-convention)):

```yaml
- id: <connection_id>           # e.g. obs_yibc, atem_saitama, obs (if global)
  module: "<module-id>"         # the manifest id
  label: "<Human Label>"        # appears in Companion UI; sanitized for variable refs
  enabled: true
  config:
    host: "192.168.1.X"
    port: <port>
    # ... other module-specific fields
```

### Module-specific gotchas

| Module | Required field |
|--------|---------------|
| `yamaha-rcp` | `isFirstInit: true` (else upgrade script crashes — see [troubleshooting](../reference/troubleshooting.md#yamaha-module-crashes-findrcpcmd-undefined)) |
| `renewedvision-propresenter` | `sendPresentationCurrentMsgs: "disabled"` (Pro7 stability), `timerPolling: "enabled"` |
| `bitfocus-obs-websocket` | `host`, `port` (default 4455), `password` |
| `bmd-atem` | `host`; module talks proprietary protocol on port 9910 |
| `homeassistant-server` | `host` (with `http://` or `https://` prefix), `access_token` (long-lived token) |

For multi-location systems, suffix the connection ID with location (`<base>_<location>`):

```yaml
- id: obs_yibc
  module: "bitfocus-obs-websocket"
  label: "OBS (YIBC)"
  enabled: true
  config:
    host: "192.168.1.50"
    port: "4455"
    password: "yibc-obs-password"

- id: obs_saitama
  module: "bitfocus-obs-websocket"
  label: "OBS (Saitama)"
  enabled: true
  config:
    host: "192.168.10.50"
    port: "4455"
    password: "saitama-obs-password"
```

## Step 3 — Identify available actions

Pages reference connections via `<connection_id>:<action_id>`. You need the verified action IDs.

Check [action-ids.md](../reference/action-ids.md) and [module-action-reference.md](../integrations/module-action-reference.md). If your module isn't there:

### Extract action IDs from a running pod

```bash
ssh pi-edge-1 "kubectl exec -n companion deploy/companion -- node -e \"\
  const m = require('/companion/modules/<module-name>/main.js');\
  const inst = new m({});\
  inst.init && inst.init();\
  console.log(JSON.stringify(Object.keys(inst.getActions() || {}), null, 2));\
\""
```

This dumps action IDs. For options on each action, dig deeper:

```bash
ssh pi-edge-1 "kubectl exec -n companion deploy/companion -- node -e \"\
  const m = require('/companion/modules/<module-name>/main.js');\
  const inst = new m({});\
  inst.init && inst.init();\
  console.log(JSON.stringify(inst.getActions(), null, 2));\
\"" | head -200
```

Document the verified action IDs in `docs/companion/integrations/<module>.md` and reference from [action-ids.md](../reference/action-ids.md).

## Step 4 — Add buttons referencing the connection

In a page YAML (existing or new), add buttons that call the new connection:

```yaml
- row: 0
  col: 0
  style:
    text: "STREAM"
    bgcolor: "#555555"
  actions:
    down:
      - action: obs_yibc:toggle_streaming
  feedbacks:
    - type: obs_yibc:streaming
      style:
        bgcolor: "#CC0000"
        text: "● LIVE"
```

## Step 5 — Document in `systems/`

Create `docs/companion/systems/<system>.md` with:

- System overview
- Network address and credentials (or where credentials live — Sealed Secret reference)
- Action IDs in use
- Pages that depend on it
- Known quirks

This is the per-system canonical doc. Cross-link from the page docs that use it.

## Step 6 — Validate + commit

```bash
python3 apps/companion/scripts/companion-deploy.py generate
# look for parse errors; check that the new connection appears in the output
git add apps/companion/config/connections.yaml docs/companion/systems/<system>.md
git commit -m "feat: add <system> connection at <location>"
git push
```

## Step 7 — Verify post-deploy

```bash
ssh pi-edge-1 "kubectl logs -n companion job/companion-deploy --tail=50"
```

Open Companion web UI → Connections → confirm the new connection shows green status. Then test a button.

## Common pitfalls

- **Wrong action ID**: silently no-ops. Always verify against the module's actual action map.
- **Wrong option key**: e.g. `index` instead of `clockIndex`. Same silent failure.
- **Forgot `isFirstInit` on yamaha-rcp**: module crashes during upgrade. Connection stays red.
- **Forgot `sendPresentationCurrentMsgs: disabled` on Pro7**: connection cycles green/red.
- **Variable references use connection ID instead of sanitized label**: variables show `$NA` in button text.

## Cross-references

- Connection registry: [connection-ids.md](../reference/connection-ids.md)
- Action ID lookup: [action-ids.md](../reference/action-ids.md)
- Variables: [variables.md](../reference/variables.md)
- Troubleshooting: [troubleshooting.md](../reference/troubleshooting.md)
- Per-system docs: `docs/companion/systems/`
