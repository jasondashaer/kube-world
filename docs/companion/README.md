# Companion Documentation

Single source of truth for the Bitfocus Companion subsystem of kube-world.

## What This Is

Companion runs on pi-edge-1, controlling Stream Decks at two church locations (YIBC, Saitama). Configs live in YAML, get generated into a `.companionconfig` blob, and import into Companion via its tRPC WebSocket API. The whole thing is GitOps — push to git, Stream Decks update.

## Where to Start

| If you want to... | Read |
|---|---|
| Understand the whole system | [ARCHITECTURE.md](ARCHITECTURE.md) |
| Understand the deploy flow | [PIPELINE.md](PIPELINE.md) |
| Learn agent conventions | [`apps/companion/CLAUDE.md`](../../apps/companion/CLAUDE.md) |
| See what's at each church | [locations/](locations/) |
| Look up a Stream Deck device | [devices/](devices/) |
| Look up a system integration | [systems/](systems/) |
| Find what a button does | [pages/](pages/) |
| Look up an action ID | [reference/action-ids.md](reference/action-ids.md) |
| Add a new Stream Deck | [guides/add-new-stream-deck.md](guides/add-new-stream-deck.md) |
| Add a new system | [guides/add-new-system.md](guides/add-new-system.md) |
| Add a new location | [guides/add-new-location.md](guides/add-new-location.md) |
| Onboard a new operator | [guides/setup-from-scratch.md](guides/setup-from-scratch.md) |
| Deploy a config change | [guides/deploy-config-changes.md](guides/deploy-config-changes.md) |
| Diagnose an issue | [reference/troubleshooting.md](reference/troubleshooting.md) |

## Inventory

| Location | Devices | Systems |
|---|---|---|
| YIBC | Stream Deck+ (PTZ control), Stream Deck MK2 (Ops) | Yamaha TF5, ProPresenter v18.4, PTZ Camera, Home Assistant |
| Saitama | Stream Deck XL (Full Production) | Yamaha TF1, ProPresenter v21.3, ATEM, OBS, ProPresenter |

See [INVENTORY.md](INVENTORY.md) for flat list of every device/IP/channel/preset.

## Status

Current deployed state, surfaces connected, last commit: see [STATUS.md](STATUS.md).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Critical Rule

**Never modify Companion via web UI.** Karmada will revert deployment changes; manual config imports get overwritten by the next git-driven deploy. All changes go through git.

```
git push  →  Flux  →  Karmada  →  ConfigMap  →  Job  →  Companion  →  Stream Decks
```
