# Page 44: Service Segments (Saitama / Stream Deck XL)

Source: `apps/companion/config/pages/saitama/xl-page05-segments.yaml`

## Purpose

Segment-transition pad for the Saitama XL. Recalls Yamaha TF1 scenes by number and writes a label into `service_mode`. Unlike the MK2 page 31 (5×3, Bank A only), the XL grid has room for both **Bank A primary segments** (engineer-edited working scenes) and a **Bank B alternate row** (canonical baselines pushed from git via `mixer-state-deploy.py`). The Bank B row exists so an engineer can recall a clean baseline mid-service if a Bank A scene has drifted into a bad state.

8×4 grid (32 buttons, no encoders).

## Page summary

| Field | Value |
|-------|-------|
| Page number | 44 |
| Name | Segments |
| Device | Stream Deck XL (8×4) |
| Source YAML | `apps/companion/config/pages/saitama/xl-page05-segments.yaml` |
| Mixer connection | `yamaha_saitama` (Yamaha TF1 at `192.168.10.30`) |
| Bank A scenes | 1–8 (primary + auxiliary) |
| Bank B scenes | 1–4 (canonical baselines, code-pushed) |
| Sibling pages on XL | [40 Home](saitama-xl-40-home.md), [41 Audio](saitama-xl-41-audio.md), [42 ProP](saitama-xl-42-prop.md), [43 Stream](saitama-xl-43-stream.md) |

## Grid layout

```
┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│ANNCE │WORSHP│SERMON│GREET │status│      │      │ time │  ← row 0 primary + status
│ A:1  │ A:2  │ A:3  │ A:4  │      │      │      │HH:MM │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│PRELUD│OFFER │COMMUN│INVITE│      │      │      │      │  ← row 1 auxiliary
│ A:5  │ A:6  │ A:7  │ A:8  │      │      │      │      │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│ANNCE │WORSHP│SERMON│GREET │      │      │      │      │  ← row 2 Bank B alternates
│  B   │  B   │  B   │  B   │      │      │      │      │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│←HOME │AUDIO │ PROP │STREAM│      │      │      │      │  ← row 3 nav
│  40  │  41  │  42  │  43  │      │      │      │      │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
```

Saitama channel mapping (TF1 inputs, used by the underlying scenes — not by buttons on this page): Worship=1, Guitar=4, Keys=6, Pastor=11, Media=14.

## Button-by-button

### Row 0 — Primary segments (Bank A) + status + clock

| Pos | Label | Press Action | service_mode set | Target | Notes |
|-----|-------|--------------|------------------|--------|-------|
| 0/0 | ANNOUNCE | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:1, Y:1}` | `Announcements` | TF1 Bank A scene 01 | |
| 0/1 | WORSHIP | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:2, Y:1}` | `Worship` | TF1 Bank A scene 02 | |
| 0/2 | SERMON | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:3, Y:1}` | `Sermon` | TF1 Bank A scene 03 | |
| 0/3 | GREETING | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:4, Y:1}` | `Greeting` | TF1 Bank A scene 04 | |
| 0/4 | status pad | — | — | Companion | `$(internal:custom_service_mode)` + `$(Yamaha_TF1__Saitama_:curScene)` |
| 0/5 | (reserved) | — | — | — | Spacer |
| 0/6 | (reserved) | — | — | — | Spacer |
| 0/7 | `$(internal:time_hms)` | — | — | Companion | Wall clock |

### Row 1 — Auxiliary segments (Bank A, scenes 5–8)

| Pos | Label | Press Action | service_mode set | Target | Notes |
|-----|-------|--------------|------------------|--------|-------|
| 1/0 | PRELUDE | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:5, Y:1}` | `Prelude` | TF1 Bank A scene 05 | |
| 1/1 | OFFERING | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:6, Y:1}` | `Offering` | TF1 Bank A scene 06 | |
| 1/2 | COMMUNION | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:7, Y:1}` | `Communion` | TF1 Bank A scene 07 | Saitama-specific (no equivalent at YIBC) |
| 1/3 | INVITATION | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:8, Y:1}` | `Invitation` | TF1 Bank A scene 08 | |
| 1/4–1/7 | (reserved) | — | — | — | Spacers |

### Row 2 — Bank B alternates (canonical baselines)

These four buttons recall Bank B scenes — the **code-pushed pristine baselines** stored by `mixer-state-deploy.py` from `apps/companion/config/scenes/saitama/*.yaml`. The row exists so an engineer can recall a clean baseline mid-service if Bank A scene N has drifted (e.g. an accidental wrong store-to-A overwrote a working sermon scene with a worship-time mix).

| Pos | Label | Press Action | service_mode set | Target | Notes |
|-----|-------|--------------|------------------|--------|-------|
| 2/0 | ANNCE B | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:1, Y:2}` | `Announcements (B)` | TF1 Bank B scene 01 | Pristine baseline |
| 2/1 | WORSHIP B | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:2, Y:2}` | `Worship (B)` | TF1 Bank B scene 02 | Pristine baseline |
| 2/2 | SERMON B | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:3, Y:2}` | `Sermon (B)` | TF1 Bank B scene 03 | Pristine baseline |
| 2/3 | GREET B | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:4, Y:2}` | `Greeting (B)` | TF1 Bank B scene 04 | Pristine baseline |
| 2/4–2/7 | (reserved) | — | — | — | Spacers |

Styled muted (`#1A1A33` bg, dim text) to mark them as recovery / advanced controls — engineers should reach for the row 0 primaries first.

A Bank B recall does **not** copy Bank B → Bank A. The mixer is now playing the Bank B contents directly. To make the recovery permanent, the engineer can do a `STORE A` from the front panel after the recall, or do a B → A copy via TF Editor — see [scene-strategy.md §4.4](../guides/scene-strategy.md#44-copy-bank-b---bank-a).

### Row 3 — Navigation to sibling XL pages

| Pos | Label | Press Action | Target |
|-----|-------|--------------|--------|
| 3/0 | ← HOME | `internal:set_page {page: 40}` | XL Page 40 Home |
| 3/1 | AUDIO | `internal:set_page {page: 41}` | XL Page 41 Audio Mixer |
| 3/2 | PROP | `internal:set_page {page: 42}` | XL Page 42 ProPresenter |
| 3/3 | STREAM | `internal:set_page {page: 43}` | XL Page 43 Stream |
| 3/4–3/7 | (reserved) | — | — |

## Connection dependencies

| Connection ID | Required for | Status if missing |
|---------------|--------------|-------------------|
| `yamaha_saitama` | All segment buttons + status pad | Recalls fail, `curScene` does not update |

No OBS / ATEM / ProPresenter dependencies on this page — pure mixer-side transitions.

## Encoder configuration

N/A — XL has no encoders.

## Known issues / TODOs

- **Bank B contents are not yet pushed.** Only `apps/companion/config/scenes/saitama/03-sermon.yaml` exists today. Until `mixer-state-deploy.py --apply` runs against the TF1, Bank B scenes 1, 2, 4 are factory-blank and pressing the Bank B alternates for those segments will silence the room.
- **Bank A scene numbers are placeholders.** Verify Bank A scenes 1–8 exist on the TF1 with the intended contents.
- **Recall Safe must be set globally** on the TF1 — otherwise any segment recall snaps the master fader and stream-send Mix bus. See [scene-strategy.md §3](../guides/scene-strategy.md#3-recall-safe--global-protection).
- **`curScene` variable label**: status pad assumes Companion sanitizes `Yamaha TF1 (Saitama)` → `Yamaha_TF1__Saitama_`. Confirm in the Variables tab on first deploy.

## Related

- Sibling pages on this surface: [40 Home](saitama-xl-40-home.md), [41 Audio](saitama-xl-41-audio.md), [42 ProP](saitama-xl-42-prop.md), [43 Stream](saitama-xl-43-stream.md)
- Scene strategy and Bank A/B workflow: [guides/scene-strategy.md](../guides/scene-strategy.md)
- Yamaha RCP namespace: [reference/yamaha-rcp-namespace.md](../reference/yamaha-rcp-namespace.md)
- Action IDs: [reference/action-ids.md](../reference/action-ids.md)
- Source YAML: [`apps/companion/config/pages/saitama/xl-page05-segments.yaml`](../../../apps/companion/config/pages/saitama/xl-page05-segments.yaml)
- Canonical scene YAMLs (Bank B source): [`apps/companion/config/scenes/saitama/`](../../../apps/companion/config/scenes/saitama/)
- Companion subsystem conventions: [`apps/companion/CLAUDE.md`](../../../apps/companion/CLAUDE.md)
