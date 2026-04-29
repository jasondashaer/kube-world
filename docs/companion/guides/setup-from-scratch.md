# Guide: Setup Stream Deck Operator From Scratch

Onboarding doc for someone who has never touched the Companion config and needs to either (a) operate the existing setup or (b) make their first config change. Designed to be the "first thing to read" pointed to from the README.

## What this system does

Bitfocus Companion runs on a Pi at each church/AV location. Each Pi controls Stream Decks on the local LAN. The Stream Decks fire actions in connected systems (Yamaha mixer, ProPresenter, OBS, PTZ camera, etc.). Configuration is **defined in YAML in this git repo** and deployed automatically by GitOps. Never edit Companion through the web UI — your changes will be reverted within ~1 minute.

## Reading order

Read these in sequence, in full, before making changes:

1. **[/CLAUDE.md](../../../CLAUDE.md)** — kube-world repo overview (5 min)
2. **[apps/companion/CLAUDE.md](../../../apps/companion/CLAUDE.md)** — Companion subsystem critical conventions (10 min)
3. **[ARCHITECTURE.md](../ARCHITECTURE.md)** — system design (10 min)
4. **[PIPELINE.md](../PIPELINE.md)** — GitOps deployment flow (10 min)
5. **[locations/<loc>.md](../locations/)** — your specific location's spec (5 min)
6. **[pages/README.md](../pages/README.md)** — page registry, then the specific page docs you'll work on (10-30 min)
7. **[reference/troubleshooting.md](../reference/troubleshooting.md)** — skim, return to when something breaks

After reading, you should be able to answer:

- Where does the YAML config for my location live?
- How do changes get to the running Companion?
- What action ID syntax do I use for the Yamaha mixer?
- What happens if I edit Companion through the web UI?

If any of these are fuzzy, re-read the relevant doc.

---

## Key files to know

| File | What it is |
|------|------------|
| `apps/companion/config/connections.yaml` | All module connections |
| `apps/companion/config/variables.yaml` | All custom variables |
| `apps/companion/config/surfaces.yaml` | Stream Deck registration |
| `apps/companion/config/triggers.yaml` | Automation triggers |
| `apps/companion/config/pages/<loc>/*.yaml` | Page button layouts |
| `apps/companion/scripts/companion-deploy.py` | YAML → tRPC importer |
| `apps/companion/deployment.yaml` | K8s deployment (TZ, env, init container) |
| `docs/companion/reference/action-ids.md` | Verified action IDs by module |
| `docs/companion/reference/troubleshooting.md` | Failure modes |

---

## Daily workflow

### Adding/changing a button

1. Find the page YAML for the page you want to change: `apps/companion/config/pages/<loc>/<file>.yaml`.
2. Edit the YAML. Use existing buttons as templates; copy patterns rather than inventing.
3. Verify action IDs against [reference/action-ids.md](../reference/action-ids.md). Common mistake: inventing an action that doesn't exist (silent no-op).
4. Run `python3 apps/companion/scripts/companion-deploy.py generate` to validate parse + check for warnings.
5. Commit + push (see [deploy-config-changes.md](deploy-config-changes.md)).
6. Wait for deploy (~1 min), test on Stream Deck.

### Adding a new page

1. Pick a free page number in your location's range (see [pages/README.md](../pages/README.md)).
2. Copy an existing page YAML as a starting template.
3. Update `page.number`, `page.name`, all buttons.
4. Add a doc at `docs/companion/pages/<loc>-<device>-<num>-<name>.md` following the existing patterns.
5. Cross-link the doc from [pages/README.md](../pages/README.md).
6. Commit + push.

### Adding a new connection / system

See [add-new-system.md](add-new-system.md). Most common case: adding OBS or ATEM (currently TBD in connections.yaml).

### Adding a new Stream Deck

See [add-new-stream-deck.md](add-new-stream-deck.md).

### Investigating a problem

1. Open [troubleshooting.md](../reference/troubleshooting.md) — skim symptoms, jump to matching section.
2. Check Companion pod logs:
   ```bash
   ssh pi-edge-1 "kubectl logs -n companion deploy/companion --tail=100"
   ```
3. Check the most recent deploy job:
   ```bash
   ssh pi-edge-1 "kubectl logs -n companion job/companion-deploy --tail=100"
   ```
4. If still stuck, escalate (see "where to ask for help" below).

---

## Things you should NOT do

| Don't | Why |
|-------|-----|
| Edit Companion through the web UI | Karmada reverts within 1 minute |
| `kubectl edit` the Companion deployment | Same |
| Add a connection without `isFirstInit: true` (Yamaha) | Module crashes |
| Add a connection without `sendPresentationCurrentMsgs: disabled` (Pro7) | Connection cycles |
| Use `internal:variable_set` | Action doesn't exist; use `custom_variable_set_value` |
| Use `internal:page_set` | Action doesn't exist; use `set_page` |
| Recreate the Companion PVC | Loses persistent data (DB cache, internal vars marked `persist: true`) |
| Hardcode UUIDs from one ProPresenter instance into another's page YAML | UUIDs are per-instance |

---

## Where to ask for help

In order of preference:

1. **Search this docs tree** — most issues are documented under `docs/companion/`.
2. **Check Companion's GitHub issues** for module-specific bugs: `bitfocus/companion-module-<module-name>`.
3. **Bitfocus Slack** — `#companion-help` channel.
4. **The maintainer** — Jackson (jax3200@gmail.com).

When asking, include:
- Companion pod logs (last 100 lines)
- The YAML you changed (paste into the message)
- What you expected vs what happened
- Whether the issue reproduces after a fresh deploy

---

## Cross-references

- Architecture: [ARCHITECTURE.md](../ARCHITECTURE.md)
- Pipeline: [PIPELINE.md](../PIPELINE.md)
- Deploy workflow: [deploy-config-changes.md](deploy-config-changes.md)
- Critical conventions: [apps/companion/CLAUDE.md](../../../apps/companion/CLAUDE.md)
