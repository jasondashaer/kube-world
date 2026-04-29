# Page 43: Stream (Saitama / Stream Deck XL)

Source: `apps/companion/config/pages/saitama/xl-page04-stream.yaml`

## Purpose

Dedicated streaming and recording surface. Full row of OBS scenes (8 of them), ATEM transition controls (AUTO, CUT, FTB), stream/record toggle with red-state feedback, and reserved buttons for a future Blackmagic recorder integration.

8×4 grid.

## Grid layout

```
┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│ OBS  │ ATEM │      │      │      │      │Recor-│ time │   ← row 0 status
│ ●OK  │ ●OK  │      │      │      │      │ der  │HH:MM │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│ Main │Camera│Slides│ PiP  │ Wide │Intro │Outro │ BRB  │   ← row 1 OBS scenes
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│ AUTO │ CUT  │ FTB  │      │      │      │ REC  │ STOP │   ← row 2 transitions+BM
│      │      │ ●FTB │      │      │      │ (BM) │ (BM) │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│STREAM│ REC  │Audio │      │      │      │      │←Home │   ← row 3
│Start │Start │ REC  │      │      │      │      │      │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
```

## Button-by-button

### Row 0 — Status

| Pos | Label | Action | Feedback |
|-----|-------|--------|----------|
| 0/0 | OBS | — | `obs:connected` → green `OBS ● OK` |
| 0/1 | ATEM | — | `atem:connected` → green `ATEM ● OK` |
| 0/2-5 | (blank) | — | — |
| 0/6 | Recorder | — | — | (display-only, reserved for BM status) |
| 0/7 | `$(internal:time_hms)` | — | — |

### Row 1 — OBS scenes

All buttons same pattern: press → `obs:set_current_scene {scene: <Name>}`, feedback → `obs:scene_active {scene: <Name>}` → green `● <Name>`.

| Pos | Scene name | Notes |
|-----|------------|-------|
| 1/0 | Main | |
| 1/1 | Camera | Feedback shows `● Cam` |
| 1/2 | Slides | |
| 1/3 | PiP | Picture-in-picture |
| 1/4 | Wide | |
| 1/5 | Intro | |
| 1/6 | Outro | |
| 1/7 | BRB | Be-Right-Back / interlude |

All scene names must exist in the OBS scene collection on the streaming workstation. Mismatched names produce no error; the scene simply won't switch.

### Row 2 — Transitions + recorder

| Pos | Label | Press | Feedback | Target | Notes |
|-----|-------|-------|----------|--------|-------|
| 2/0 | AUTO | `atem:auto_transition` | — | ATEM | Verify action ID against atem-mini module |
| 2/1 | CUT | `atem:cut_transition` | — | ATEM | Verify action ID |
| 2/2 | FTB | `atem:toggle_ftb` | `atem:ftb_active` → red `● FTB` | ATEM | Fade-to-black toggle |
| 2/3-5 | (blank) | — | — | — | — |
| 2/6 | REC (BM) | (no action) | — | — | Placeholder for Blackmagic recorder |
| 2/7 | STOP (BM) | (no action) | — | — | Placeholder |

### Row 3 — Stream/Record + nav

| Pos | Label | Press | Feedback | Target |
|-----|-------|-------|----------|--------|
| 3/0 | STREAM Start | `obs:toggle_streaming` | `obs:streaming` → red `● LIVE Stop?` | OBS |
| 3/1 | REC Start | `obs:toggle_recording` | `obs:recording` → red `● REC Stop?` | OBS |
| 3/2 | Audio REC | (no action) | — | — | Placeholder |
| 3/3-6 | (blank) | — | — | — | — |
| 3/7 | ← Home | `internal:set_page {page: 40}` | — | Companion |

## Connection dependencies

| Connection ID | Required for | Status |
|---------------|--------------|--------|
| `obs` | OBS status, all row 1 scenes, STREAM, REC | **Not yet defined in connections.yaml** |
| `atem` | ATEM status, AUTO/CUT/FTB | **Not yet defined in connections.yaml** |

## Known issues / TODOs

- **`obs` and `atem` connections not in `connections.yaml`** — entire page is non-functional until these are added.
- **Action IDs unverified**: `obs:toggle_streaming`, `obs:toggle_recording`, `obs:set_current_scene`, `obs:scene_active`, `atem:auto_transition`, `atem:cut_transition`, `atem:toggle_ftb`, `atem:ftb_active` are all assumed. Run a connection test and validate against actual module exports — see [guide: add-new-system](../guides/add-new-system.md).
- **Blackmagic recorder integration** is fully stubbed (3 buttons reserved). Determine which Blackmagic Companion module to use (`bmd-hyperdeck`, `bmd-atem`, etc.).
- **Audio REC button (3/2)** has no action — intent unclear. Either remove or wire to a separate audio-recording target.
- **Scene names must match OBS exactly** — case-sensitive. Recommend snapshotting OBS scene collection and committing names alongside this page.

## Cross-references

- Parent: [Page 40 Home](saitama-xl-40-home.md)
- Sibling pages: [Page 41 Audio](saitama-xl-41-audio.md), [Page 42 ProP](saitama-xl-42-prop.md)
- Add-system guide: [guides/add-new-system.md](../guides/add-new-system.md)
