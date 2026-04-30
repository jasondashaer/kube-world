# Environment Strategy: Dev / Prod Separation + Deploy Modes

This document describes how kube-world segments development from production
work, how changes promote from dev → prod, and the two deploy modes the
Companion subsystem supports across that lifecycle.

## Two questions that need separate answers

1. **Where does code live and how does it promote to production?** (env strategy)
2. **What runs on each Pi at each site?** (deploy mode)

Conflating them produces the worst of both: dev work bleeds into production,
or production sites run an over-complicated stack the operators can't
maintain.

---

## 1. Environment strategy

### Decision: single repo, tag-gated production

```
┌──────────────────────────────────────────────────────────────────┐
│                       jasondashaer/kube-world                     │
├──────────────────────────────────────────────────────────────────┤
│                                                                  │
│  main (always-current)                                           │
│   ↓ Flux on dev cluster (pi-edge-1 today, home Pi long-term)     │
│   ↓ auto-deploys every push                                      │
│                                                                  │
│  prod-vN (signed tag)                                            │
│   ↓ Flux on prod cluster (cloud / future home cluster)           │
│   ↓ auto-deploys only when a `prod-v*` tag appears               │
│                                                                  │
│  Promotion path:                                                 │
│   1. Develop on main (or feature branch → MR → main)             │
│   2. Validate on dev cluster                                     │
│   3. Cut signed tag: `git tag -s prod-vN -m '...' && git push`   │
│   4. Prod cluster picks up the new tagged commit + reconciles    │
└──────────────────────────────────────────────────────────────────┘
```

### Why this and not the alternatives

| Alternative | Why rejected |
|---|---|
| Two separate repos (kube-world-dev / kube-world-prod) | Drift inevitable; double maintenance; merge tooling overhead. Real isolation comes from cluster-side enforcement, not repo-side mirrors. |
| Two GitLab instances | Same as above plus operational duplication. |
| Long-lived `prod` branch | Branch divergence + merge conflicts when prod hot-fixes. Tags are immutable; branches are not. |
| `main` + manual cherry-pick to prod | Every cherry-pick is an opportunity for human error. |
| GitOps in cloud + local stays separate | Locks production into a specific cloud provider; harder to repatriate. |

The branch+tag model gives:

- **Single source of truth** — all history in one place.
- **Cluster-enforced isolation** — prod cluster's Flux GitRepository points
  at `prod-v*` tag pattern, NOT at `main` HEAD. Dev cluster points at
  `main`. A push to `main` cannot reach prod.
- **Signed tags as audit trail** — `git tag -s` requires GPG signature.
  Who promoted what to production is recorded by signature.
- **Reversible** — to rollback: re-tag a known-good earlier commit as
  `prod-vN+1`. Prod reconciles to the tagged state.

### What lives in `main` vs what's tagged

Everything lives in `main`. Tags are pointers to specific commits that
have been validated for production. There's no separate "prod content".

This means:

- A YAML edit to a production-only setting still gets committed to `main`
  and reviewed there.
- Per-environment values diverge via kustomize overlays
  (`overlays/dev/`, `overlays/prod/`), not by branching the codebase.
- Dev validates the change first; if it works, the same commit gets tagged.

### MR pipeline (matches the work-pattern you described)

`.gitlab-ci.yml` (when GitLab runner is online):

| Stage | When | Purpose |
|---|---|---|
| `validate` | Every commit + every MR | YAML lint, kustomize build, companion-deploy.py generate, schema check |
| `dev:apply` | Manual on MR (pre-merge OK) | Dry-run kustomize apply against dev cluster — shows the diff |
| `prod:apply` | Tag-gated, only post-merge | Dry-run apply against prod cluster — same job, different cluster context |

The `dev:apply` job mirrors what you described from work: dev jobs
runnable pre-merge, prod jobs only after merge (here: only after tag).

### Branch protection rules to set on GitLab

- `main`: require MR + approval; no direct push
- Tags matching `prod-v*`: require signature; require maintainer role to
  create
- All other tags: allowlisted developers may create (e.g. `dev-test-*`
  for ad-hoc dev cluster tests)

---

## 2. Deploy modes

### Decision: support both, mode chosen at deploy-time

| Mode | Where runs | Stack | When |
|---|---|---|---|
| **vanilla** | Bare Pi at production sites | Just Companion as a systemd service | TODAY at YIBC + Saitama. Operator-owned. |
| **k3s** | Pi or cloud cluster | Full kube-world stack (K3s + Karmada + Flux + Companion + auto-import) | Dev (today). Prod (when you've moved to Japan and can self-service). |

### Code organization

Both modes share the same source YAML in `apps/companion/config/`. The
deploy mode determines what consumes that YAML:

```
apps/companion/
  config/                        ← single source of truth (YAML)
  scripts/
    companion-deploy.py          ← consumed by k3s init container OR
                                   one-shot via vanilla install
    mixer-state-deploy.py        ← operator-run, mode-agnostic
    seed-export.py               ← generates handoff .companionconfig
  deployment.yaml                ← K3s manifest (k3s mode)
  kustomization.yaml             ← K3s kustomize root (k3s mode)
  gitops/                        ← K3s GitOps pipeline (k3s mode)

deploy/
  vanilla/                       ← vanilla mode artifacts
    install.sh                   ← bare-Pi systemd installer
    companion.service            ← systemd unit
    site/                        ← per-site overrides (host/secrets)
      yibc/.env.example
      saitama/.env.example
    handoff/                     ← what operators receive
      README.md
      seed-export-instructions.md

overlays/                        ← kustomize overlays (k3s mode env split)
  dev/
    kustomization.yaml
  prod/
    kustomization.yaml
```

### Vanilla mode characteristics

- Companion installed via `deploy/vanilla/install.sh` (one command, runs on the Pi).
- Systemd unit (`companion.service`) auto-starts on boot.
- Initial config seeded from `seed-export.py` output (one-time import via
  Companion web UI).
- All operator changes thereafter are **direct** — they edit via web UI,
  no GitOps loop.
- Repo is not the source of truth at vanilla sites; it's just where the
  seed came from. Drift is expected and acceptable.
- Backups: TF Editor (mixer side) + Companion's built-in export (config
  side). Operators run these on a schedule.
- Remote help: Tailscale or Ubiquiti VPN gives you SSH/web access for
  occasional troubleshooting. Read-only insurance, not load-bearing.

### k3s mode characteristics

- Companion runs as a Deployment, hostNetwork=true, on a K3s cluster.
- Auto-import: any push to the watched branch/tag updates Companion via
  tRPC import.
- Karmada handles multi-cluster scheduling (single cluster works without it).
- Flux is the GitOps engine.
- All changes flow through git — operator does NOT use the web UI for
  permanent changes; Karmada will revert them.
- Repo IS the source of truth.
- Secrets via Sealed Secrets controller (encrypted in git, decrypted in
  cluster).
- Observability via the broader kube-world stack (Prometheus, Grafana,
  Velero).

### Mode selection: where it's encoded

| Decision | Where it lives |
|---|---|
| Which Pi runs which mode | `deploy/vanilla/site/<site>/MODE` file (literal `vanilla` or `k3s`) |
| Vanilla site list | Generated at build-time from `deploy/vanilla/site/*/MODE` |
| k3s cluster list | `karmada/propagation-policies/companion.yaml` clusterAffinity |

For the production handoff: pick `vanilla` per site. When you eventually
move to Japan and decide to bring up a prod K3s cluster, you flip a
specific site from vanilla to k3s by:

1. Cutover: stop systemd Companion on Pi, install K3s on Pi (or join an
   existing cluster), apply kube-world manifests.
2. Migrate: import the Pi's current Companion config back to YAML via
   `companion-deploy.py export`, diff against repo, commit any drift.
3. Repo continues unchanged afterward — same YAML now drives the new mode.

---

## 3. How both states inform what we build now

Today's work targets State 1 (vanilla handoff for YIBC + Saitama) AND
prepares for State 2 (full k3s prod cluster, eventually).

| Workstream | Vanilla (today) | K3s (future) | Where to put effort now |
|---|---|---|---|
| Companion config (pages, triggers, connections) | Yes (seed import) | Yes (auto-import) | Same — YAML is shared |
| Smooth fades / scene Recall hybrid | Yes | Yes | Same — runtime behavior is identical |
| `mixer-state-deploy.py` | Operator runs from laptop | Operator runs from laptop (NOT auto) | Same |
| Sealed Secrets | Manual `.env` file on Pi | Sealed Secret in cluster | Build BOTH paths now — Sealed Secret CR for k3s, env-file pattern for vanilla, both consumed by same companion-deploy.py |
| OAuth flows (Spotify, OBS WS) | Operator does once via web UI | Sealed Secret pre-injects token | Document both. Vanilla = simple. K3s = automated. |
| GitOps pipeline | N/A (no GitOps at vanilla sites) | Flux + Karmada + tRPC import (already built) | Already built; document mode-switching |
| MR pipeline / .gitlab-ci.yml | Validate stage relevant for catching errors before handoff updates | Full validate + dev-apply + prod-apply | Build it now, mostly skeletal until GitLab runner online |
| Site-specific docs | Yes | Yes | Same `docs/companion/locations/<site>.md` |
| Handoff guide | Yes | Yes (different content but same role) | Build vanilla version now; k3s version when prod cluster planned |

### What NOT to build now (will distract)

- Don't move existing files to a `deploy/k3s/` subdirectory. Causes Flux
  pointer breakage, churn, and gains nothing — `apps/`, `karmada/`,
  `flux/`, `infrastructure/` already implicitly mean "k3s mode."
- Don't build a config promotion tool that auto-syncs vanilla site
  configs back to git. Vanilla = drift is expected.
- Don't build cross-mode data migration scripts beyond the export-back-
  to-YAML one (`companion-deploy.py export`). Cutover is rare enough
  to warrant manual review per site.

---

## 4. Roadmap matrix

| Initiative | Vanilla blocker? | K3s prod blocker? | Status |
|---|---|---|---|
| Vanilla install script + systemd unit | YES | no | TBD |
| seed-export.py | YES | no | TBD |
| Site handoff guide | YES | no | TBD |
| OAuth/Sealed Secrets foundation | partial (manual env file works) | YES | TBD |
| dev/prod kustomize overlays | no | YES | TBD |
| `.gitlab-ci.yml` skeleton | no | YES | TBD |
| Stale page docs refresh | no (but useful for handoff) | no | TBD |
| Missing scene YAMLs | no (but useful for handoff baseline) | no | TBD |
| Live-test runbook | no (already done) | no | DONE |
| ARM-gated triggers | no (already done) | no | DONE |
| Segment-transition pads | no (already done) | no | DONE |
| Hybrid scene-strategy doc | no (already done) | no | DONE |

---

## Cross-references

- Vanilla install: `deploy/vanilla/install.sh`
- Vanilla handoff: `docs/companion/guides/site-handoff.md`
- K3s deploy script: `apps/companion/scripts/companion-deploy.py`
- K3s pipeline: `docs/companion/PIPELINE.md`
- Operator scene strategy: `docs/companion/guides/scene-strategy.md`
- Live test runbook: `docs/companion/guides/live-test-runbook.md`
- RCP namespace: `docs/companion/reference/yamaha-rcp-namespace.md`
