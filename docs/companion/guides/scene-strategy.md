# Guide: Scene Strategy (Hybrid Bank A / Bank B Model)

How this project manages Yamaha TF scenes across two locations (YIBC TF5, Saitama TF1) without breaking Companion automation when a sound engineer needs to tweak settings during a service.

For the underlying RCP namespace and command verbs see [yamaha-rcp-namespace.md](../reference/yamaha-rcp-namespace.md). For Companion action IDs see [action-ids.md](../reference/action-ids.md). Project conventions live in [apps/companion/CLAUDE.md](../../../apps/companion/CLAUDE.md).

---

## 1. The problem

Three naive approaches all fail in production:

| Approach | Failure mode |
|---|---|
| **Code-only scenes** (push every param via RCP every service) | Brittle: a single bad RCP write nukes a known-good board state mid-service. Engineer has no easy recovery path. |
| **Mixer-only scenes** (engineer authors and stores from front panel) | Drift: scenes evolve in the mixer with no version control; no cross-location consistency; rebuilding TF after factory-reset means re-authoring from memory. |
| **Full RCP-push every service** | High blast radius: if the mixer is in an unexpected state, a push can introduce silent issues (pre/post wrong, phantom power off on a critical mic) that surface mid-service. |

We need: code-managed canonical scenes (version-controlled, reproducible) **plus** engineer freedom to refine in real time without git involvement.

---

## 2. The hybrid model

TF series exposes two banks of 100 scenes (A and B). We assign roles:

| Bank | Owner | Editable from | Purpose |
|---|---|---|---|
| **A** | Sound engineer | Front panel, TF Editor | **Working scenes** — what the service actually uses. Companion's segment-transition pads recall these. Engineer can edit freely and store back to A. |
| **B** | `mixer-state-deploy.py` | RCP push from git-tracked YAML | **Canonical reference scenes** — pristine baseline. Used to reset Bank A scene N to a known-good state if drift is bad. |

Companion's segment-transition pads (page 31 YIBC, page 44 Saitama — see future docs `pages/yibc-mk2-31-segments.md` and `pages/saitama-xl-44-segments.md`) call:

```yaml
- action: yamaha_yibc:MIXER_Lib/Bank/Scene/Recall
  options: { X: 1, Y: 5 }   # X=bank (1=A), Y=scene number
```

Bank A scene numbers are the stable contract. The engineer can rewrite the contents of bank A scene 5 freely; as long as the number stays 5, the Companion button keeps working.

---

## 3. Recall Safe — global protection

TF series only supports **global** Recall Safe (no per-scene Focus Recall — see [yamaha-rcp-namespace.md §4.1](../reference/yamaha-rcp-namespace.md#41-recall-safe-mixersetuprecallsafe)). One protection list applies to every recall on the console.

Recommended Recall Safe protections for both YIBC and Saitama:

| Param | Why |
|---|---|
| Stereo master fader (`Setup/RecallSafe/St/On X=1 Val=1`) | Room volume must not snap on segment transition. Engineer rides the master fader manually. |
| Mix 17 (`Setup/RecallSafe/Mix/On X=17 Val=1`) | Stream send bus — should not change per service segment. |
| Mix 21, Mix 22 (YIBC TF5 only) | Record-feed buses. |
| Headamp gain on critical mics | Phantom power state and analog gain are physical-world settings; protect them so a scene recall can't disable phantom on a condenser mid-song. Apply per-port: `Setup/RecallSafe/HA/On X=<port> Val=1`. |
| All DCAs (`Setup/RecallSafe/DCA/On X=1..8 Val=1`) | DCA fader positions are dynamic / engineer-controlled; protect them from scene snap. |

Set Recall Safe **once per console** (during initial commissioning); it persists across power cycles.

```
set MIXER:Setup/RecallSafe/St/On 1 0 1
set MIXER:Setup/RecallSafe/Mix/On 17 0 1
set MIXER:Setup/RecallSafe/Mix/On 21 0 1
set MIXER:Setup/RecallSafe/Mix/On 22 0 1
set MIXER:Setup/RecallSafe/DCA/On 1 0 1
... (DCA 2-8) ...
set MIXER:Setup/RecallSafe/HA/On 1 0 1     # repeat per protected port
```

`mixer-state-deploy.py --apply-recall-safe` (planned) automates this.

---

## 4. Workflow — first-time scene setup

```
YAML author --> dry-run --> apply --> store-to-B --> manual copy B->A --> Companion recalls A
```

### 4.1 Author the scene declaratively

Create `apps/companion/config/scenes/<location>/<scene-name>.yaml`. Schema (planned, mirrors RCP leaves):

```yaml
location: yibc           # yibc | saitama
scene_number: 3          # bank A and bank B both store at this number
title: "03-Sermon"
comment: "Pastor lav hot, music down"

channels:
  1:
    label: "Pastor"
    color: 7              # Red
    fader_db: -6.0
    on: true
    ha_gain_db: 35.0
    phantom: true
    sends:
      mix_1:  { level_db: 0.0, on: true, prepost: post }
      mix_17: { level_db: -3.0, on: true, prepost: post }   # stream
  2:
    label: "Lectern"
    fader_db: -inf
    on: false
  # ...
mix:
  17: { fader_db: 0.0, on: true, label: "Stream" }
dca:
  1: { label: "Vocals", fader_db: 0.0, on: true }
```

Commit to git. This is the source of truth.

### 4.2 Dry-run

```bash
python3 apps/companion/scripts/mixer-state-deploy.py \
    --location yibc --scene 03-sermon --dry-run
```

Produces a list of RCP commands that **would** be sent. No mixer connection required. Use to review before service day.

### 4.3 Apply (when mixer is reachable and backed up)

```bash
python3 apps/companion/scripts/mixer-state-deploy.py \
    --location yibc --scene 03-sermon --apply
```

Script behavior:

1. Connects to the TF on TCP 49280.
2. Writes a console snapshot to a backup file (current state as YAML) before any change.
3. Sets every leaf in the YAML via `set ...` RCP commands.
4. After all writes succeed, executes `ssstore_ex MIXER:Lib/Bank/Scene 2 <scene_number>` to store to bank B.
5. Sets bank B title and comment.
6. Reports success.

### 4.4 Copy bank B -> bank A

This step is **manual** (intentionally). The engineer reviews the bank B scene, decides whether it's safe to make it the active working scene, then copies B -> A:

- **TF Editor**: open Scene Library, select bank B scene N, click "Store From Library" -> bank A scene N.
- **Front panel**: SCENE menu -> select source (B/N) -> Store -> destination (A/N).

Now Companion's button (which recalls bank A scene N) gets the new state.

### 4.5 Companion recalls bank A

No code change needed — segment buttons already point at bank A scene N.

---

## 5. Workflow — service-day adjustments

| Step | Who | Where |
|---|---|---|
| 1. During service, engineer notices pastor lav needs +2 dB on Mix 17 | Engineer | Front panel |
| 2. Engineer adjusts Mix 17 send | Engineer | Front panel fader |
| 3. After song, engineer stores Bank A scene N | Engineer | Front panel: STORE -> bank A scene N |
| 4. Next service uses updated scene | -- | Automatic — Companion still recalls bank A |

No git commit. No code deploy. The scene number is stable; the contents evolved on the mixer.

If the change is permanent and worth canonicalizing back to git, see Section 6.

---

## 6. Workflow — code-side update

Engineer wants to permanently bump pastor channel HA gain by 3 dB across all sermon scenes.

| Step | Action |
|---|---|
| 1 | Edit `apps/companion/config/scenes/yibc/03-sermon.yaml`: `ha_gain_db: 35.0 -> 38.0` |
| 2 | `git commit && git push` |
| 3 | Flux deploys the new ConfigMap to pi-edge-1. **The deploy ConfigMap reflects the new YAML but does NOT auto-push to the mixer.** This is intentional — pushing to a live mixer should be deliberate and operator-supervised. |
| 4 | Operator schedules a quiet window (between services). |
| 5 | Operator runs `python3 mixer-state-deploy.py --location yibc --scene 03-sermon --apply`. Bank B scene 3 updates. |
| 6 | At next opportunity (between services), operator copies bank B scene 3 -> bank A scene 3 from front panel or TF Editor. |
| 7 | Next service uses the updated scene. |

The decoupling between "git change deployed" and "mixer state pushed" is by design. Companion config can update from git automatically because the worst case is a Stream Deck button mislabeled. Mixer state cannot, because the worst case is a phantom-power flip mid-song.

---

## 7. Gotchas

| Gotcha | Detail |
|---|---|
| **Scene numbers are stable contracts** | Never renumber a scene without updating the corresponding Companion segment button's `Y:` (scene number) value AND any Bank B canonical baseline. The number is what Companion recalls. |
| **Bank A and Bank B share scene numbering space** | Scene 03 in A and scene 03 in B are two different stored snapshots. They are not synchronized; copying A->B or B->A is always manual. |
| **Scene 00 is factory blank** | "Initial Data" in either bank is a hard reset (all faders to -inf, all labels cleared). Don't recall scene 00 mid-service unless intentional. |
| **TF Editor caches** | TF Editor and the front panel both write to the same scene library and see each other's changes immediately. But TF Editor caches scene contents on open — after an RCP push from `mixer-state-deploy.py`, refresh TF Editor (close and reopen the scene library window) before relying on what it shows. |
| **Recall Safe is global** | Setting a bus safe protects it for **every** scene recall on this console. There's no way to say "Mix 17 is safe in scene 3 but not in scene 5". If you need that, it's a CL/QL/Rivage feature. |
| **HA addresses by port, not channel** | If you re-patch (move pastor mic from port 1 to port 5), the scene's stored HA gain follows the port unless Recall Safe is set on the port. Verify channel-to-port patches before pushing scenes. |
| **`isFirstInit: true` on Companion connection** | Required on `yamaha_yibc` and `yamaha_saitama` connections — see [apps/companion/CLAUDE.md](../../../apps/companion/CLAUDE.md). Unrelated to scene strategy but trips up scene-recall actions silently if missing. |
| **Mute is inverted** | `Fader/On: 0` = muted. Easy to confuse when authoring scene YAML. The YAML schema uses `on: true/false` instead of raw 0/1 to keep this readable. |

---

## 8. Mental model summary

```
git (YAML)  --[mixer-state-deploy.py --apply]-->  Bank B (canonical)
                                                       |
                                              [manual B->A copy]
                                                       v
Engineer (front panel) <--[STORE A]--> Bank A (working) <--[Recall]-- Companion
```

- Bank B is the version-controlled mirror of git.
- Bank A is the live engineer-owned working set.
- Companion always reads from A.
- B is your safety net if A drifts unrecoverably.

---

## Cross-references

- [reference/yamaha-rcp-namespace.md](../reference/yamaha-rcp-namespace.md) — protocol detail, address tree, value scaling
- [reference/action-ids.md](../reference/action-ids.md) — Companion action IDs for scene recall/store
- [pages/yibc-mk2-31-segments.md](../pages/yibc-mk2-31-segments.md) — segment transition page (planned)
- [pages/saitama-xl-44-segments.md](../pages/saitama-xl-44-segments.md) — segment transition page (planned)
- [apps/companion/CLAUDE.md](../../../apps/companion/CLAUDE.md) — project conventions
- `apps/companion/scripts/mixer-state-deploy.py` — RCP push tool (planned, referenced throughout this doc)
