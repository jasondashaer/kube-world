# Companion Troubleshooting Reference

Comprehensive failure-mode catalog. Each entry: symptom → cause → fix → prevention.

If a new failure mode is encountered, add it here so the next operator (or Claude) can diagnose without re-discovering it.

---

## Companion UI returns 404

**Symptom**: `curl http://<pi-ip>:8000` returns 404 or connection refused. Web UI shows nothing. Companion pod logs look normal.

**Cause**: K3s embedded etcd got stuck binding to a previous network's IP. When the Pi changes networks (or DHCP lease changes), etcd doesn't always rebind cleanly. Companion's Service in K8s ends up routing to a non-existent endpoint.

**Diagnose**:

```bash
ssh pi-edge-1 "sudo systemctl status k3s | head -20"
ssh pi-edge-1 "sudo ss -tlnp | grep 6443"   # API server should bind to current LAN IP
ssh pi-edge-1 "kubectl get endpoints -n companion"
```

**Fix**: power cycle the Pi, OR `ssh pi-edge-1 "sudo systemctl restart k3s"`. Wait 60s, retry.

**Prevention**: assign DHCP reservations for all Pis. Avoid changing the Pi's LAN.

---

## `unable to open database file`

**Symptom**: Companion pod crashloops. Logs contain `Error: unable to open database file` or similar SQLite errors.

**Cause**: The PVC was created with root-owned files (or the PVC was wiped and re-mounted with default perms). Companion runs as uid 1000 and can't write to `/companion/data/db`.

**Fix**: ensure the deployment has the init container that chowns the PVC mount:

```yaml
initContainers:
  - name: fix-perms
    image: busybox
    command: ["sh", "-c", "chown -R 1000:1000 /companion"]
    volumeMounts:
      - name: data
        mountPath: /companion
    securityContext:
      runAsUser: 0
```

Check `apps/companion/deployment.yaml` — the init container should already exist. If missing, add it, commit, push.

**Prevention**: never recreate the PVC manually. Always commit deployment.yaml changes through git.

---

## Yamaha module crashes `findRcpCmd undefined`

**Symptom**: Yamaha connection shows red. Companion logs (or module logs) contain stack trace involving `upg2xxto30x` and `findRcpCmd is undefined`.

**Cause**: The module's upgrade script tries to migrate older action data, but the connection has no actions yet (fresh import). It blows up dereferencing an empty action list.

**Fix**: in `connections.yaml`, add `isFirstInit: true` to the Yamaha config:

```yaml
- id: yamaha_yibc
  module: "yamaha-rcp"
  config:
    host: "192.168.1.54"
    model: "TF"
    isFirstInit: true   # ← required
```

The generator (`scripts/companion-deploy.py`) should set this flag automatically for `yamaha-rcp` connections; verify the generator output includes it. Then redeploy.

**Prevention**: always set `isFirstInit: true` for new yamaha-rcp connections. Document required for any new Yamaha mixer added.

---

## Stream Deck shows IP / Setup screen after import

**Symptom**: After deploying a config change, the Stream Deck displays its IP address and "Setup mode" screen instead of buttons.

**Cause**: The Companion config import wiped the registered surfaces table. Companion no longer knows about the Stream Deck.

**Fix**: re-register the surface. Two options:

1. **Manual**: open Companion web UI → Surfaces → Add → Network surface (Elgato outbound) → enter Stream Deck IP.
2. **Automated**: add a post-import hook in `companion-deploy.py` that calls `surfaces.outbound.add` via tRPC for each entry in `surfaces.yaml`.

If `surfaces.yaml` already has the surface entry but the deploy didn't re-register, check that `companion-deploy.py` runs the post-import hook. The hook should be idempotent (skip if already registered).

**Prevention**: keep `surfaces.yaml` in sync with physical Stream Decks. Use the post-import registration hook.

---

## "Entity is not a action!" UI error

**Symptom**: Companion web UI displays a red error banner: `Entity is not a action!` (or `feedback`). Buttons that triggered the import don't show their actions.

**Cause**: The generator output omits `type: "action"` (or `type: "feedback"`) on entity definitions. Companion's import iterates entities and calls type-specific handlers; missing `type` causes silent skip with this UI error.

**Diagnose**:

```bash
python3 apps/companion/scripts/companion-deploy.py generate | jq '.controls."40".steps."0".action_sets.down[0]'
# every entity should have "type": "action"
```

**Fix**: in `companion-deploy.py`, ensure every action entity has `type: "action"` and every feedback has `type: "feedback"`. The generator should add these unconditionally.

**Prevention**: lint the generator output before pushing. Add a unit test that asserts `type` on every entity.

---

## Manual env var change reverts

**Symptom**: SSH'd into the Pi, edited `kubectl edit deployment/companion -n companion` to change e.g. TZ. Within ~30 seconds, the change reverts.

**Cause**: Karmada controller reconciles the deployment to match the source YAML in git. Imperative kubectl edits are overwritten.

**Fix**: edit `apps/companion/deployment.yaml` in the git repo, commit, push. Wait for Flux + Karmada to reconcile.

**Prevention**: never edit deployments imperatively. All changes through git, period.

---

## ProPresenter drops connection repeatedly

**Symptom**: ProPresenter connection cycles green → red → green every few seconds. Module logs contain reconnect attempts.

**Cause**: Pro7 instability when the module sends `presentation_current_msgs` requests. This is a known module bug.

**Fix**: in `connections.yaml`, set `sendPresentationCurrentMsgs: "disabled"`:

```yaml
- id: propresenter_saitama
  module: "renewedvision-propresenter"
  config:
    sendPresentationCurrentMsgs: "disabled"
    timerPolling: "enabled"
```

Both YIBC and Saitama already have this set; verify any new PP connection includes it.

**Prevention**: always set `sendPresentationCurrentMsgs: "disabled"` on any `renewedvision-propresenter` connection.

---

## Encoder rotation never stops

**Symptom**: rotating a PTZ encoder makes the camera move continuously and never stop, even after rotation event ends.

**Cause**: encoder action does not include a trailing `ptz:stop`. PTZ VISCA `left`/`right`/`up`/`down` are continuous-motion commands.

**Fix**: use the move + wait + stop pattern:

```yaml
rotate_cw:
  - action: ptz:right
  - action: internal:wait
    options: { time: "10 + ($(internal:custom_ptz_speed) - 1) * 15" }
  - action: ptz:stop
```

**Prevention**: never use bare `ptz:left`/`right`/`up`/`down` in encoder actions. Always followed by wait + stop. (D-pad button press-and-release is fine because the release event triggers stop.)

---

## Time displayed is wrong

**Symptom**: `$(internal:time_hms)` shows UTC instead of local time, or some other wrong timezone.

**Cause**: the Companion pod has no `TZ` env var set, so it defaults to UTC.

**Fix**: in `apps/companion/deployment.yaml`, set the TZ env var:

```yaml
spec:
  containers:
    - name: companion
      env:
        - name: TZ
          value: "Asia/Tokyo"   # or America/Los_Angeles, etc.
```

Commit through git. Karmada will roll out the new pod.

**Prevention**: always set `TZ` per-location. Document in the location-specific docs.

---

## "Cannot read property of undefined (reading 'iterable')"

**Symptom**: import fails on a button with `steps`. Stack trace mentions `iterable`.

**Cause**: the step is missing `runWhileHeld: []` in its options. Companion expects this array on every step.

**Fix**: in `companion-deploy.py`, ensure step options include `runWhileHeld: []`:

```python
step["options"] = {"runWhileHeld": [], **other_step_options}
```

The generator should add this for every step. If you see this error after a fresh import, the generator regression-tested missing this — fix and redeploy.

**Prevention**: generator test asserts `runWhileHeld` is present in every step.

---

## Feedback styling crashes (`Cannot read .text`)

**Symptom**: import succeeds but Companion logs contain `Cannot read property 'text' of undefined` whenever a feedback fires.

**Cause**: feedback `style` block has only `bgcolor` (or only `text`) but not all required fields. `visitButtonDrawStyle` accesses `style.text` unconditionally.

**Fix**: when defining feedback styles, include ALL fields (or none). Required when style is non-empty:

```yaml
feedbacks:
  - type: yamaha_yibc:MIXER_Current/St/Fader/On
    options: { X: 1, Val: 0 }
    style:
      text: "MUTE"
      size: 14
      color: "#FFFFFF"        # ← required
      bgcolor: "#CC0000"
      alignment: "center:center"  # ← required
      show_topbar: false      # ← required
```

The generator should fill in safe defaults for missing fields.

**Prevention**: generator emits all 6 fields (text, size, color, bgcolor, alignment, show_topbar) whenever any one is set.

---

## WebSocket flake on import

**Symptom**: `companion-deploy.py` exits with `WebSocket connection failed` or hangs partway through import. Sometimes succeeds on retry.

**Cause**: Tailscale link to the Pi is slow or congested; tRPC WebSocket times out before the import completes.

**Fix**: re-run the deploy. The Job in K8s retries automatically up to its backoff limit.

**Prevention**: increase `companion-deploy.py` WebSocket timeout. Run the deploy when Tailscale is stable. For very large config imports, batch into multiple smaller imports.

---

## Pages don't appear after import

**Symptom**: import succeeds, but new page YAML doesn't show up on Stream Deck. Companion shows page numbers but blank buttons.

**Cause**: page is missing `id` (nanoid) or `gridSize` block.

**Fix**: in `companion-deploy.py`, ensure every page in the import has:

```python
{
    "id": nanoid(),
    "name": page["name"],
    "gridSize": {"minColumn": 0, "maxColumn": 4, "minRow": 0, "maxRow": 3},
    # ... etc
}
```

**Prevention**: generator unit test asserts every page has `id` and `gridSize`.

---

## Connection import fails silently

**Symptom**: a new connection added to `connections.yaml` doesn't appear in Companion after import.

**Cause**: missing required field in the generated connection record. Companion needs:

- `moduleInstanceType: "connection"`
- `sortOrder` (int)
- `secrets: {}`
- `lastUpgradeIndex` (int)
- `enabled: true`

Plus the module-specific config block.

**Fix**: verify `companion-deploy.py` adds all 5 universal fields to every connection. Check the generated tRPC payload.

**Prevention**: generator test that every connection has all 5 universal fields.

---

## Step option `runWhileHeld` already covered above

(See "Cannot read property of undefined (reading 'iterable')")

---

## Symptom-to-fix index

| Symptom | Section |
|---------|---------|
| 404 on web UI | [Companion UI returns 404](#companion-ui-returns-404) |
| `unable to open database` | [unable to open database file](#unable-to-open-database-file) |
| `findRcpCmd undefined` | [Yamaha module crashes](#yamaha-module-crashes-findrcpcmd-undefined) |
| Stream Deck shows IP | [Stream Deck shows IP / Setup screen](#stream-deck-shows-ip--setup-screen-after-import) |
| `Entity is not a action!` | [Entity is not a action error](#entity-is-not-a-action-ui-error) |
| Imperative edits revert | [Manual env var change reverts](#manual-env-var-change-reverts) |
| PP connection drops | [ProPresenter drops connection](#propresenter-drops-connection-repeatedly) |
| Encoder won't stop | [Encoder rotation never stops](#encoder-rotation-never-stops) |
| Wrong timezone | [Time displayed is wrong](#time-displayed-is-wrong) |
| `iterable` error on import | [Cannot read iterable](#cannot-read-property-of-undefined-reading-iterable) |
| Feedback `.text` crash | [Feedback styling crashes](#feedback-styling-crashes-cannot-read-text) |
| Import hangs / fails | [WebSocket flake](#websocket-flake-on-import) |
| Page is blank | [Pages don't appear](#pages-dont-appear-after-import) |
| Connection missing | [Connection import fails silently](#connection-import-fails-silently) |

---

## Cross-references

- Generator: `apps/companion/scripts/companion-deploy.py`
- Connection conventions: [connection-ids.md](connection-ids.md)
- Module action IDs: [action-ids.md](action-ids.md)
- Deployment workflow: [guides/deploy-config-changes.md](../guides/deploy-config-changes.md)
- Architecture: [docs/companion/ARCHITECTURE.md](../ARCHITECTURE.md)
