# Companion GitOps Pipeline

End-to-end flow from `git push` to a Stream Deck button rendering the new layout. See also: [ARCHITECTURE.md](ARCHITECTURE.md), [INVENTORY.md](INVENTORY.md), [STATUS.md](STATUS.md).

## 1. Pipeline at a Glance

```
[1] dev workstation: edit YAML, git commit, git push
       |
[2] GitHub receives push -> mirror to GitLab (gitlab.kubew.dev)
       |
[3] Flux source-controller (pi-central) reconciles GitRepository
       |
[4] Flux kustomize-controller applies Kustomization to Karmada API
       |
[5] Karmada PropagationPolicy fans out to pi-edge-1
       |
[6] pi-edge-1 K3s API: ConfigMap companion-config updated
       |
[7] Job companion-deploy: triggered by ConfigMap checksum annotation
       |
[8] Job pod runs companion-deploy.py against http://companion.companion.svc:8000
       |
[9] companion-deploy.py: YAML -> .companionconfig -> tRPC WebSocket import
       |
[10] Companion core: parse, replace state, restart modules
       |
[11] Surfaces auto-reassigned to startup pages from surfaces.yaml
       |
[12] Stream Decks repaint with new layout
```

Typical end-to-end latency: **60-120 seconds** depending on Flux reconcile interval and import size.

## 2. Step-by-Step

### Step 1 — Developer commits and pushes

| Field | Value |
|-------|-------|
| **Trigger** | `git push origin main` |
| **What runs** | Local pre-commit hooks (if any). |
| **State change** | New commit on GitHub `main`. |
| **Failure modes** | Lint/yaml-validation hook rejection. Unsigned commit policy (none currently). |

### Step 2 — GitHub -> GitLab mirror

| Field | Value |
|-------|-------|
| **Trigger** | GitHub webhook OR GitLab pull-mirror cron (whichever is configured). |
| **What runs** | GitLab pulls latest from GitHub. |
| **State change** | `gitlab.kubew.dev/root/kube-world` HEAD advances. |
| **Failure modes** | Mirror credentials expired; network partition between GitLab and GitHub. |
| **Detect** | `gitlab.kubew.dev` -> repo -> Settings -> Repository -> Mirroring -> last sync timestamp. |

### Step 3 — Flux source-controller reconciles

| Field | Value |
|-------|-------|
| **Trigger** | `GitRepository` reconcile interval (default 1m) or manual `flux reconcile source git kube-world`. |
| **What runs** | source-controller fetches latest commit, stores tarball in cluster. |
| **State change** | `GitRepository/kube-world` status `lastFetchedRevision` advances. |
| **Failure modes** | GitLab deploy token revoked; TLS cert validation failure; commit not yet on GitLab (mirror lag). |
| **Detect** | `flux get sources git -A` on pi-central. |

### Step 4 — Flux kustomize-controller applies

| Field | Value |
|-------|-------|
| **Trigger** | Source revision changed OR Kustomization reconcile interval. |
| **What runs** | kustomize-controller renders `flux/kustomizations/apps.yaml` and applies the rendered manifests against the **Karmada API server** (not the local K3s API). |
| **State change** | Karmada control-plane's etcd has new resource versions for ConfigMap, Deployment, Job, etc. |
| **Failure modes** | YAML parse error in ConfigMap data; Kustomize build error; Karmada API down. |
| **Detect** | `flux get kustomizations -A`; `kubectl --context karmada-apiserver get configmap -n companion`. |

### Step 5 — Karmada propagates to pi-edge-1

| Field | Value |
|-------|-------|
| **Trigger** | Karmada controller observes resource change in matched PropagationPolicy. |
| **What runs** | Karmada agent (karmada-agent on edge) writes resources to the local K3s API. ClusterOverridePolicy applies Pi-specific resource limits to Deployments. |
| **State change** | pi-edge-1 K3s sees ConfigMap/Deployment/Job updates. |
| **Failure modes** | PropagationPolicy selector mismatch; Karmada agent disconnected; namespace not yet propagated (must run after `apps-base`). |
| **Detect** | `kubectl --context karmada-apiserver get resourcebinding -A`; on pi-edge-1: `kubectl get events -n companion --sort-by=.lastTimestamp`. |

### Step 6 — ConfigMap updated on edge

| Field | Value |
|-------|-------|
| **Trigger** | K3s applies the new ConfigMap manifest. |
| **What runs** | Nothing yet — ConfigMaps don't trigger pods on their own. The companion deployment is **not** subscribed to this ConfigMap (the live container reads from PVC). |
| **State change** | `kubectl get configmap companion-config -n companion -o yaml` shows new YAML. |
| **Annotation** | `kustomize.toolkit.fluxcd.io/checksum` (or our custom checksum annotation) reflects content hash. |
| **Failure modes** | ConfigMap size limit (1MB) exceeded — can happen if YAML grows large. |

### Step 7 — Job companion-deploy triggered

| Field | Value |
|-------|-------|
| **Trigger** | Kustomize re-renders the Job manifest. The Job's `metadata.name` includes the ConfigMap content checksum (e.g. `companion-deploy-abc123`), so a content change creates a **new Job object**, which K3s schedules. |
| **What runs** | Job spawns a single pod (Python image with `pyyaml`, `websocket-client`). |
| **State change** | New `Job` resource and child Pod in `companion` namespace. |
| **RBAC** | ServiceAccount + Role from `gitops/rbac.yaml` — read ConfigMap, list pods. |
| **Failure modes** | Image pull failure; ServiceAccount missing; Pod scheduling failure (toleration mismatch). |
| **Detect** | `kubectl get jobs -n companion`; `kubectl logs -n companion job/companion-deploy-<hash>`. |

### Step 8 — Job pod runs the importer

| Field | Value |
|-------|-------|
| **Trigger** | Pod starts. |
| **What runs** | `python3 /scripts/companion-deploy.py generate` then `... import --url http://companion.companion.svc:8000`. |
| **State change** | None on disk yet — operates entirely over the network. |
| **Network** | Job pod (in cluster network, not hostNetwork) connects to the **ClusterIP Service** `companion.companion.svc:8000`, which routes to the Companion pod's hostNetwork:8000. |
| **Failure modes** | Companion pod not Ready (livenessProbe takes 90s on cold start); WebSocket upgrade rejected; tRPC schema mismatch. |

### Step 9 — Generate and upload

| Field | Value |
|-------|-------|
| **What runs** | `companion-deploy.py`: walks `/scripts/../config/**/*.yaml`, builds in-memory dict in Companion's native schema, writes `companion.companionconfig` (gzipped JSON). |
| **Upload protocol** | tRPC over WebSocket (`ws://.../trpc`): `importExport.prepareImport.start` -> `uploadChunk` (512KB base64 chunks) -> `complete` (with SHA1 checksum) -> `importFull`. |
| **State change** | Companion's in-memory import session populated; no DB write yet. |
| **Failure modes** | Schema-version mismatch (we set `version: 9`, `companionBuild: "4.2.6+8823-stable"`); SHA1 mismatch on `complete`; chunk loss. |

### Step 10 — Companion executes the import

| Field | Value |
|-------|-------|
| **Trigger** | `importFull` mutation. |
| **What runs** | Companion clears existing pages/triggers/customVariables/connections, writes new ones to sqlite, restarts module subprocesses. |
| **Import config** | `buttons: reset-and-import`, `surfaces: known: unchanged` (preserve surface registrations), `triggers: reset-and-import`, `customVariables: reset-and-import`, `connections: reset`, `userconfig: unchanged`. |
| **State change** | `/companion/v4.2/db.sqlite` rewritten. New page IDs (nanoid) generated each import — surface assignments must be re-resolved. |
| **Failure modes** | Module load error (missing module, bad config); `findRcpCmd undefined` if `isFirstInit: false`; "Entity is not a action!" if `type` field missing on action entity. |

### Step 11 — Surfaces reassigned to startup pages

| Field | Value |
|-------|-------|
| **Trigger** | After `importFull`, the deployer reads `surfaces.yaml`, fetches the live export to map page numbers -> new page IDs, then for each surface group calls `surfaces.groupSetConfigKey` three times (`startup_page_id`, `last_page_id`, `use_last_page=false`). |
| **State change** | sqlite surface-group rows updated. |
| **Failure modes** | Surface group ID drift (we set them to `streamdeck:<serial>` — should be stable); page number mismatch (page 40 not in import). |
| **Note** | If a Stream Deck shows the IP/Setup screen after import, surfaces were wiped (use the `unchanged` strategy as we do, not `reset`). |

### Step 12 — Stream Decks repaint

| Field | Value |
|-------|-------|
| **Trigger** | Companion pushes new button bitmaps over the existing TCP connection to each deck. |
| **State change** | Deck OLEDs render new layout. |
| **Failure modes** | Deck disconnected (decks reconnect automatically); Pi LAN IP changed and decks are still pointing at old IP (re-config required at the deck setup screen). |

## 3. Idempotency and Replay

| Property | Detail |
|----------|--------|
| **Re-running same commit** | ConfigMap checksum unchanged -> Job name unchanged -> already-completed Job, no re-import. To force: `kubectl delete job -n companion -l app=companion-deploy`. |
| **Rolling back** | `git revert <sha> && git push`. Pipeline runs in reverse. ~60-120s to take effect. |
| **Manual emergency import** | From dev workstation: `python3 apps/companion/scripts/companion-deploy.py import --url https://companion.edge1.kubew.dev`. Use only when GitOps pipeline broken. |
| **What survives import** | Surface registrations (Stream Deck pairings), userconfig, PVC contents (logs, cache). |
| **What gets wiped** | Pages, buttons, triggers, custom variables, connection definitions (re-imported fresh). |

## 4. Failure Detection Cheatsheet

| Symptom | Likely Stage | Diagnosis |
|---------|--------------|-----------|
| YAML change not visible in Companion UI | Step 3 or 5 | `flux get all -A` on pi-central; check Karmada propagation status. |
| ConfigMap updated but no Job ran | Step 7 | Checksum annotation didn't change (regenerate). Or Job already exists with same name. |
| Job pod CrashLoopBackOff | Step 8/9 | `kubectl logs -n companion job/companion-deploy-<hash>` — usually websocket connection timeout (Companion pod not Ready). |
| Job logs "tRPC error on importExport.importFull" | Step 10 | Schema mismatch or invalid entity. Look for "Entity is not a action!" in Companion pod logs. |
| Companion UI returns 404 forever | Edge infra | K3s etcd stuck on old IP after Pi network move. `systemctl restart k3s`. |
| Stream Deck stuck on Setup screen | Step 11 | Surface assignment lost. Check `surfaces.yaml` group_id matches deck serial. |
| `findRcpCmd undefined` in Yamaha module | Step 10 | Missing `isFirstInit: true`. Deployer always sets it; check generator output. |
| ProPresenter drops repeatedly | Module config | `sendPresentationCurrentMsgs` not set to `disabled` for Pro7. |
| Manual UI change reverted within 1m | Working as designed | Karmada/Flux reconciles. Edit YAML, commit, push. |

## 5. Reconcile Knobs

| Knob | Default | Where |
|------|---------|-------|
| Flux GitRepository interval | 1m | `flux/sources/git-repository.yaml` |
| Flux Kustomization interval | 10m | `flux/kustomizations/apps.yaml` |
| Karmada propagation delay | a few seconds | controller-manager |
| Job pod startup | ~5s | image pull cached |
| Companion liveness initialDelay | 90s | `deployment.yaml` |
| WebSocket connect retry | hardcoded ~3s wait | `companion-deploy.py` |
| tRPC response timeout | 30s | `companion-deploy.py` |

## 6. Manual Override Procedures

| Goal | Command |
|------|---------|
| Force Flux to re-fetch | `flux reconcile source git kube-world` |
| Force Kustomization apply | `flux reconcile kustomization apps` |
| Force re-import (bypass GitOps) | `kubectl delete job -n companion -l app=companion-deploy` then commit a no-op |
| Inspect generated config | `python3 apps/companion/scripts/companion-deploy.py generate` -> reads `apps/companion/config/companion.json` |
| Pull live config back to YAML | `python3 apps/companion/scripts/companion-deploy.py export --url https://companion.edge1.kubew.dev` (writes `companion-export.json` for diffing only) |
| Restart Companion pod | `kubectl rollout restart deployment/companion -n companion` |

## 7. Cross-References

- System architecture and rationale: [ARCHITECTURE.md](ARCHITECTURE.md)
- Hardware that the imports target: [INVENTORY.md](INVENTORY.md)
- Last known operational state: [STATUS.md](STATUS.md)
- Conventions and gotchas: `apps/companion/CLAUDE.md`
