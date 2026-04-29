# CLAUDE.md — Companion Subsystem Agent Context

This file gives an AI agent the context needed to reason about the Companion subsystem of kube-world without re-discovering hard-won lessons.

## Overview

Bitfocus Companion v4.2 controls Stream Decks across two church locations (YIBC, Saitama). Configs are defined in YAML, generated into a `.companionconfig` blob, and imported via Companion's tRPC WebSocket API. The whole pipeline runs as GitOps: YAML in git → Flux on pi-central → Karmada → pi-edge-1 → ConfigMap → Job → companion-deploy.py → tRPC → Companion.

**Single source of truth: `apps/companion/config/*.yaml`**. Never modify the live Companion via web UI. All changes go through git.

## Critical Conventions (do not deviate)

### Config Generator (`scripts/companion-deploy.py`)

- Entity import format requires `definitionId` (not `actionId`/`feedbackId`). Companion's internal storage uses `definitionId`; export reverses to `actionId`/`feedbackId`.
- Every action entity needs `type: "action"`. Every feedback needs `type: "feedback"`. Missing causes silent skip and "Entity is not a action!" UI error.
- Controls are nested `controls[row][col]` (NOT flat `"row/col"` keys). Companion's `#ql` import iterates rows then columns.
- Step options must include `runWhileHeld: []` array. Missing causes "Cannot read property of undefined (reading 'iterable')".
- Pages need `id` (nanoid) and `gridSize` (`{minColumn, maxColumn, minRow, maxRow}`).
- Connections need `moduleInstanceType: "connection"`, `sortOrder`, `secrets`, `lastUpgradeIndex`, `enabled`.
- For `yamaha-rcp`: set `isFirstInit: true` on the connection. Otherwise upgrade scripts (`upg2xxto30x`) crash with `findRcpCmd undefined`.
- Feedback styles must include all fields when `style` is non-empty (not just bgcolor): `text`, `size`, `color`, `bgcolor`, `alignment`, `show_topbar`. Companion's `visitButtonDrawStyle` accesses `.text` unconditionally.

### Stream Deck+ Encoder Grid

- Plus reports as 4 cols × 4 rows.
- Rows 0-1: physical button area.
- Row 2: LCD strip (4 zones, pressable buttons — visible button text).
- Row 3: rotary encoder knobs (`rotaryActions: true`, action sets keyed by `rotate_left`/`rotate_right` not `rotate_cw`/`rotate_ccw`).

### Module Action IDs (verified)

| Module | Notes |
|---|---|
| `ptzoptics-visca` | Action IDs are short — `left`, `right`, `up`, `down`, `home`, `stop`, `zoomI`, `zoomO`, `zoomS`, `focusN`, `focusF`, `focusS`, `focusM`, `recallPreset`, `setPreset`, `ptSpeedU`, `ptSpeedD`, `ptSpeedSet`, `power`, `custom`. Preset options need `{isText: false, presetAsNumber: N}`. |
| `yamaha-rcp` | Action IDs use RCP address with `:` → `_`: `MIXER_Current/InCh/Fader/On`, `MIXER_Current/St/Fader/Level`, `MIXER_Lib/Bank/Scene/Recall`. Options use `X`, `Y`, `Val` and optional `Rel: true` for relative fader changes. **Mute logic inverted**: `Val: 1` = on (unmuted), `Val: 0` = muted. Fader scale: `-32768` = -∞dB, `0` = 0dB, `1000` = +10dB (100 units = 1dB). |
| `renewedvision-propresenter` | `next`, `last`, `slideNumber`, `clearall`, `clearslide`, `clockStart`, `clockStop`, `clockReset`, `pro7SetLook`, `pro7TriggerMacro`. **Pro7 stability: must set `sendPresentationCurrentMsgs: "disabled"`** or connection drops repeatedly. Set `timerPolling: "enabled"` for timer variables. |
| `internal` | `custom_variable_set_value` (NOT `variable_set`), `custom_variable_set_expression`, `set_page` (NOT `page_set`), `step_delta` (NOT `step_next`/`step_set`), `wait`. |

### Smooth Audio Fades (workaround)

Yamaha TF RCP has no native fade duration parameter. Smooth fades implemented as a sequence of `Fader/Level` commands separated by `internal:wait`. See `pages/yibc/mk2-page01-ops.yaml` duck button — 20 steps × 50ms = 1 sec fade.

### Multi-Bus Fading

When fading multiple buses (e.g. stereo master + front-fill aux), maintain dB offset throughout fade by computing aux value as `master_value + offset_in_units`. Example: aux at -6dB offset → aux value = master + -600.

### Connection Naming

Two parallel sets per shared module to support both locations simultaneously:

- `yamaha_yibc` (TF5, 192.168.1.54) — used by YIBC pages (Plus, MK2)
- `yamaha_saitama` (TF1, 192.168.10.30) — used by Saitama pages (XL)
- `propresenter_yibc` (192.168.1.2:1025, pass=YIBC) — YIBC pages
- `propresenter_saitama` (192.168.68.55:53678, pass=test1234) — Saitama pages
- `ptz` (192.168.1.113) — YIBC only (no PTZ at Saitama)

Whichever location the Pi is at, the unused location's connections show disconnected. Status indicators reflect that. Acceptable tradeoff.

## Network Topology Realities

- Pi-edge-1 runs Companion with `hostNetwork: true` so it uses the Pi's local LAN, not K8s pod network.
- Stream Decks connect via outbound Elgato TCP to whatever LAN address the Pi was given by DHCP.
- When the Pi changes networks, K3s embedded etcd can get confused. Symptom: Companion web UI returns 404, etcd binds to old IP. Fix: power cycle Pi or `systemctl restart k3s`.
- When relocating, all surface IPs (Stream Decks + camera + mixer + ProPresenter) likely change. Update via the GitOps config commit, not by editing Companion UI.

## GitOps Pipeline

```
git push (GitLab+GitHub)
  ↓
Flux on pi-central reconciles GitRepository
  ↓
Flux applies Kustomization → Karmada control plane
  ↓
Karmada propagates to pi-edge-1
  ↓
ConfigMap (companion-config) updated with YAML files
  ↓
Job (companion-deploy) triggered by ConfigMap checksum annotation
  ↓
Job runs companion-deploy.py against http://companion.companion.svc:8000
  ↓
Companion imports new config via tRPC
  ↓
Stream Decks reflect new config
```

**Never modify Companion via web UI.** Karmada or Flux will revert it. All changes flow through git.

## Common Failure Modes

| Symptom | Cause | Fix |
|---|---|---|
| Companion UI returns 404 forever | K3s etcd stuck on old IP | Power cycle Pi |
| `unable to open database file` in logs | PVC perms wrong (root vs uid 1000) | Init container chowns PVC; commit fix to deployment.yaml |
| Yamaha module crashes `findRcpCmd undefined` | Upgrade script running with empty action data | Set `isFirstInit: true` on connection |
| Stream Deck shows IP/Setup screen after import | Surfaces wiped during import | Re-add via `surfaces.outbound.add` (or use surfaces.yaml + post-import hook) |
| "Entity is not a action!" in UI | Missing `type: "action"` on entity | Generator already adds it; check generator output |
| Manual env var change reverts | Karmada reconciles deployment | Edit deployment.yaml in repo, commit, push |
| ProPresenter drops repeatedly | Pro7 instability sending presentation requests | Connection config: `sendPresentationCurrentMsgs: "disabled"` |
| Encoder rotation never stops | No stop after move | Use move + wait + stop pattern (see PTZ encoders) |

## File Layout

```
apps/companion/
  CLAUDE.md                          ← this file
  README.md                          ← human-facing entry
  deployment.yaml                    ← K8s deployment, Flux/Karmada-managed
  kustomization.yaml                 ← root kustomization (deployment + auto-import)
  gitops/                            ← K8s resources for auto-import pipeline
    deploy-job.yaml                  ← Deployment with init container that runs
                                       companion-deploy.py on every ConfigMap hash change
    kustomization.yaml               ← (legacy, still referenced in places)
  config/
    connections.yaml                 ← all module connections (both locations)
    variables.yaml                   ← all custom variables
    surfaces.yaml                    ← surface-to-page assignments
    triggers.yaml                    ← all triggers (automation)
    pages/yibc/*.yaml                ← YIBC pages (Plus 20-21, MK2 30-31)
    pages/saitama/*.yaml             ← Saitama pages (XL 40-44)
    scenes/<location>/*.yaml         ← Declarative mixer scene state (RCP push targets)
  scripts/
    companion-deploy.py              ← YAML → tRPC importer (also runs in-cluster Job)
    mixer-state-deploy.py            ← Operator-run RCP push to TF mixers; --dry-run + --apply

docs/companion/
  README.md                          ← navigation
  ARCHITECTURE.md                    ← system design
  PIPELINE.md                        ← GitOps flow detail
  STATUS.md                          ← current build state
  INVENTORY.md                       ← hardware + connection inventory
  locations/                         ← per-location specs
  systems/                           ← per-integration specs
  devices/                           ← per-Stream-Deck specs
  pages/                             ← per-page detailed button matrices
  reference/                         ← action-ids, variables, triggers,
                                       smooth-fades, troubleshooting,
                                       yamaha-rcp-namespace
  guides/                            ← deploy-config-changes, scene-strategy,
                                       live-test-runbook, add-new-{system,
                                       location,stream-deck}, setup-from-scratch
```

## Two Deploy Pipelines (don't confuse them)

| Pipeline | Trigger | What it touches | Auto? |
|---|---|---|---|
| `companion-deploy.py` (in-cluster Deployment init container) | git push → Flux → ConfigMap hash → rolling update | Companion config (buttons, pages, connections, triggers, surfaces) via tRPC import | YES — fires on every YAML change in `apps/companion/config/`. Pi-edge-1 only |
| `mixer-state-deploy.py` (operator-run on Mac) | manual `python3 ... --apply` | TF1/TF5 mixer state via RCP, then stores to scene slot | NO — operator runs deliberately with backup ready. Live mixer reachable from operator's laptop |

The auto-pipeline never touches the mixer directly. The operator pipeline is for code-pushed mixer scene baselines (Bank B). Bank A is engineer-owned working scenes — Companion segment-transition pads call Recall against Bank A; engineers edit Bank A on the mixer between services without touching code.

See `docs/companion/guides/scene-strategy.md` for the full hybrid model.

## When in Doubt

1. Check `docs/companion/reference/troubleshooting.md` first.
2. Check the specific page doc in `docs/companion/pages/` for what each button does.
3. Read the actual YAML — it's the source of truth, not the live Companion state.
4. Don't modify Companion via web UI. Modify YAML, commit, push.
