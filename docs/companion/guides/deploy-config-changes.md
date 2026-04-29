# Guide: Deploy Config Changes

Standard workflow for moving a YAML edit in `apps/companion/config/` to a running Companion instance.

The pipeline is fully automatic via GitOps — your only manual step is `git push`.

```
edit YAML → commit → push → Flux on pi-central → Karmada → pi-edge-1 →
  ConfigMap updated → Job triggered → companion-deploy.py runs → tRPC import → Stream Deck reflects change
```

---

## Step-by-step

### 1. Edit the YAML

In your local checkout under `apps/companion/config/`. Files:

| File | When to edit |
|------|--------------|
| `connections.yaml` | Adding/changing a system connection |
| `variables.yaml` | Adding a new custom variable |
| `surfaces.yaml` | Registering a new Stream Deck |
| `triggers.yaml` | Adding/enabling an automation trigger |
| `pages/<loc>/*.yaml` | Changing a Stream Deck page |

### 2. Validate locally

Run the generator to catch parse errors before pushing:

```bash
python3 apps/companion/scripts/companion-deploy.py generate
```

Expected: produces a `.companionconfig` blob (or pretty-printed JSON, depending on flags) without errors. If you see Python errors or YAML parse errors, fix them before committing.

The generator does NOT validate against module action IDs (it just emits whatever you wrote). Verify action IDs against [reference/action-ids.md](../reference/action-ids.md) by hand.

### 3. Commit

Use a descriptive commit message:

```bash
git add apps/companion/config/pages/saitama/xl-page02-audio.yaml
git commit -m "fix: correct pastor channel mute feedback X value"
```

Follow conventional commits if possible (`feat:`, `fix:`, `docs:`, `refactor:`).

### 4. Push to GitHub

```bash
git push origin main
```

### 5. Wait for Flux to reconcile

Flux runs on pi-central. It polls the GitLab mirror (which mirrors from GitHub). Reconcile interval is typically 1 minute. Total time from `git push` to ConfigMap update on pi-edge-1: **30 seconds to 2 minutes** depending on where in the poll cycle you push.

Watch reconciliation:

```bash
ssh pi-central "flux get kustomizations -A | grep companion"
```

The relevant kustomization should show `Last Applied: <recent>`.

### 6. Watch the deploy job

Once the ConfigMap is updated on pi-edge-1, the Job is triggered (driven by ConfigMap checksum annotation). The job runs `companion-deploy.py`:

```bash
ssh pi-edge-1 "kubectl logs -n companion job/companion-deploy -f"
```

Expected output:

```
Loading config files...
  - connections.yaml: 6 connections
  - variables.yaml: 11 variables
  - pages/yibc/mk2-page01-ops.yaml: page 30 (5x3)
  - pages/yibc/plus-page01-ptz.yaml: page 20 (4x4 + 4 encoders)
  ...
Generating .companionconfig...
Connecting to Companion at http://companion.companion.svc:8000...
Importing config (#ql)...
Import successful.
Re-registering surfaces from surfaces.yaml...
  - yibc_plus_main: registered
  - saitama_xl: registered
Done.
```

If the job logs an error, see [troubleshooting](../reference/troubleshooting.md).

### 7. Verify on Stream Deck

Look at the physical Stream Deck. Buttons should reflect the change.

If a button doesn't work as expected:

- Did the connection succeed? Check `http://<pi-ip>:8000` → Connections tab → verify green status.
- Is the action ID correct? See [action-ids.md](../reference/action-ids.md).
- Are option keys correct? E.g. `clockIndex` not `index`.

---

## Rollback

If a change breaks something live:

```bash
git revert HEAD
git push
```

Flux + Karmada will reconcile the previous version within ~1 minute. The deploy job re-runs and Companion goes back to the prior config.

For a more targeted rollback, `git revert <specific-commit>`.

---

## Things you must NOT do

### DO NOT edit Companion via the web UI

Karmada reconciles the deployment based on git. ANY change made through the web UI (buttons, connections, surfaces, variables, triggers) will be **overwritten by the next deploy**, which can fire as soon as anyone pushes anything.

If you need to experiment, do so in a development Companion instance (not the production Pi) or in a feature branch.

### DO NOT `kubectl edit` resources

Same reason. Imperative changes are reverted by reconciliation.

### DO NOT manually trigger the Job

The Job is triggered by ConfigMap checksum changes. Manually creating Job pods can race with the controller and produce inconsistent state.

### DO NOT skip generator validation

`python3 apps/companion/scripts/companion-deploy.py generate` catches YAML errors locally. If you push broken YAML, the Job will crashloop with a parse error and you'll have to push a fix.

---

## Cross-references

- Critical conventions: [apps/companion/CLAUDE.md](../../../apps/companion/CLAUDE.md)
- Pipeline architecture: [PIPELINE.md](../PIPELINE.md)
- Troubleshooting failures: [reference/troubleshooting.md](../reference/troubleshooting.md)
- Action ID validation: [reference/action-ids.md](../reference/action-ids.md)
- Deploy script: `apps/companion/scripts/companion-deploy.py`
