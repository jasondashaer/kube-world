# Page 31: Service Segments (YIBC / Stream Deck MK2)

Source: `apps/companion/config/pages/yibc/mk2-page02-segments.yaml`

## Purpose

Segment-transition pad for the MK2 at YIBC. Each primary button recalls a Yamaha TF5 **Bank A** scene by number, then writes a human-readable label into `service_mode` so the rest of the system knows where the service is. The page is reached from page 30 via the `SEGMENTS →` button (row 2 col 4) and returns there via `← OPS`.

This page is intentionally a thin shim. **Companion only knows the scene number.** The actual scene contents (channel routing, EQ, dynamics, send levels) live on the TF5 itself in Bank A and can be edited freely between services from the front panel or TF Editor without touching this YAML — see [scene-strategy.md](../guides/scene-strategy.md).

The page is a 5×3 grid (15 buttons, no encoders).

## Page summary

| Field | Value |
|-------|-------|
| Page number | 31 |
| Name | Segments |
| Device | Stream Deck MK2 (5×3) |
| Source YAML | `apps/companion/config/pages/yibc/mk2-page02-segments.yaml` |
| Parent / nav back | Page 30 Ops (`← OPS` button at 2/0) |
| Mixer connection | `yamaha_yibc` (Yamaha TF5 at `192.168.1.54`) |
| Scene bank called | Bank A (`Y: 1` in `MIXER_Lib/Bank/Scene/Recall`) |

## Grid layout

```
┌─────────┬─────────┬─────────┬─────────┬─────────┐
│ANNOUNCE │ WORSHIP │ SERMON  │GREETING │ status  │  ← row 0 primary
│ scene 1 │ scene 2 │ scene 3 │ scene 4 │ mode/sc │
├─────────┼─────────┼─────────┼─────────┼─────────┤
│ PRELUDE │OFFERING │         │         │         │  ← row 1 auxiliary
│ scene 5 │ scene 6 │         │         │         │
├─────────┼─────────┼─────────┼─────────┼─────────┤
│ ← OPS   │         │         │         │ HH:MM:SS│  ← row 2 nav + clock
└─────────┴─────────┴─────────┴─────────┴─────────┘
```

## Button-by-button

### Row 0 — Primary segments (Bank A, scenes 1–4)

| Pos | Label | Press Action | service_mode set | Target | Notes |
|-----|-------|--------------|------------------|--------|-------|
| 0/0 | ANNOUNCE | `yamaha_yibc:MIXER_Lib/Bank/Scene/Recall {X:1, Y:1}` | `Announcements` | TF5 Bank A scene 01 | Room mics + announcer mic |
| 0/1 | WORSHIP | `yamaha_yibc:MIXER_Lib/Bank/Scene/Recall {X:2, Y:1}` | `Worship` | TF5 Bank A scene 02 | Vocal + instrument layer |
| 0/2 | SERMON | `yamaha_yibc:MIXER_Lib/Bank/Scene/Recall {X:3, Y:1}` | `Sermon` | TF5 Bank A scene 03 | Pulpit + lapel only |
| 0/3 | GREETING | `yamaha_yibc:MIXER_Lib/Bank/Scene/Recall {X:4, Y:1}` | `Greeting` | TF5 Bank A scene 04 | Ambient room mics |
| 0/4 | status pad | — | — | Companion | Displays `$(internal:custom_service_mode)` and `$(Yamaha_TF5__YIBC_:curScene)` (current scene number reported by the mixer) |

`X` is the scene **number** (1–100). `Y` is the **bank** (`1`=A, `2`=B). YIBC only uses bank A on this page; the engineer-edited working scenes live there.

### Row 1 — Auxiliary segments (Bank A, scenes 5–6)

| Pos | Label | Press Action | service_mode set | Target | Notes |
|-----|-------|--------------|------------------|--------|-------|
| 1/0 | PRELUDE | `yamaha_yibc:MIXER_Lib/Bank/Scene/Recall {X:5, Y:1}` | `Prelude` | TF5 Bank A scene 05 | Pre-service ambient |
| 1/1 | OFFERING | `yamaha_yibc:MIXER_Lib/Bank/Scene/Recall {X:6, Y:1}` | `Offering` | TF5 Bank A scene 06 | Mid-service offertory |
| 1/2 | (blank) | — | — | — | Reserved |
| 1/3 | (blank) | — | — | — | Reserved |
| 1/4 | (blank) | — | — | — | Reserved |

These are styled muted (`#222244` bg, dim text) to mark them as secondary.

### Row 2 — Navigation + clock

| Pos | Label | Press Action | Target | Notes |
|-----|-------|--------------|--------|-------|
| 2/0 | ← OPS | `internal:set_page {controller: self, page: 30}` | Companion | Returns to MK2 Ops page |
| 2/1 | (blank) | — | — | Reserved |
| 2/2 | (blank) | — | — | Reserved |
| 2/3 | (blank) | — | — | Reserved |
| 2/4 | `$(internal:time_hms)` | — | Companion | Wall clock |

## Hybrid scene model — why this page is a thin wrapper

The four primary buttons (and the two auxiliary) call `MIXER_Lib/Bank/Scene/Recall` with a fixed **scene number**. The number is the contract. The engineer can re-author the contents of TF5 Bank A scene 3 from the front panel, store it back, and Companion's SERMON button keeps working — no git commit, no Companion redeploy.

Bank B is reserved for canonical pristine baselines that `mixer-state-deploy.py` writes from `apps/companion/config/scenes/yibc/*.yaml`. Bank B is **not** called from this page (the MK2 grid is too small to expose Bank B alternates — the Saitama XL page 44 includes a Bank B row for that purpose). To recall a Bank B baseline at YIBC, the engineer either:

1. Triggers it from the TF5 front panel (SCENE menu → Bank B → scene N → Recall), or
2. Does a manual Bank B → Bank A copy on the front panel, then presses the matching button on this page.

See [scene-strategy.md](../guides/scene-strategy.md) for the full Bank A / Bank B workflow and Recall Safe configuration.

## Connection dependencies

| Connection ID | Required for | Status if missing |
|---------------|--------------|-------------------|
| `yamaha_yibc` | All primary + auxiliary segment buttons | Buttons silent — RCP recall fails, `curScene` variable does not update |

No OBS / ProPresenter dependencies on this page — it is a pure mixer-side transition pad.

## Encoder configuration

N/A — MK2 has no encoders.

## Known issues / TODOs

- **Scene numbers are placeholders** — verify bank A scenes 1–6 actually exist on the TF5 with the intended contents before service. Default scene numbering (`01-announcements`, `02-worship`, etc.) follows `apps/companion/config/scenes/yibc/`.
- **Recall Safe must be set globally** on the TF5 to protect the master fader and Mix 17 stream send from snapping on a recall — see [scene-strategy.md §3](../guides/scene-strategy.md#3-recall-safe--global-protection).
- **`curScene` variable name** in the status pad assumes Companion's connection-label sanitization yields `Yamaha_TF5__YIBC_`. Confirm in the Variables tab on first deploy.
- **No audible-cue protection** — pressing a segment button takes effect immediately on the mixer. There is no two-step confirm (segment changes are routine and non-destructive, given Recall Safe).

## Related

- Sibling page on this surface: [Page 30 Ops](yibc-mk2-30-ops.md)
- Scene strategy and Bank A/B workflow: [guides/scene-strategy.md](../guides/scene-strategy.md)
- Yamaha RCP namespace and value scaling: [reference/yamaha-rcp-namespace.md](../reference/yamaha-rcp-namespace.md)
- Action ID conventions: [reference/action-ids.md](../reference/action-ids.md)
- Source YAML: [`apps/companion/config/pages/yibc/mk2-page02-segments.yaml`](../../../apps/companion/config/pages/yibc/mk2-page02-segments.yaml)
- Canonical scene YAMLs (Bank B source): [`apps/companion/config/scenes/yibc/`](../../../apps/companion/config/scenes/yibc/)
- Companion subsystem conventions: [`apps/companion/CLAUDE.md`](../../../apps/companion/CLAUDE.md)
