# Page 42: ProP (Saitama / Stream Deck XL)

Source: `apps/companion/config/pages/saitama/xl-page03-slides.yaml`

## Purpose

Dedicated ProPresenter control surface for the Saitama instance. Slide navigation, look switching (Normal/Lyrics/Scripture/Blank), multi-target clears, and timer controls including ±1 minute adjustment.

8×4 grid.

## Grid layout

```
┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│ ProP │      │      │      │      │      │      │ time │   ← row 0
│ ●OK  │      │      │      │      │      │      │HH:MM │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│ PREV │ NEXT │  GO  │      │Slide1│Slide2│Slide3│Slide4│   ← row 1
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│Normal│Lyrics│Script│Blank │      │CLEAR │CLEAR │CLEAR │   ← row 2
│      │      │      │      │      │Slide │Media │ All  │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│Timer │Timer │Timer │+1 Min│-1 Min│Mssg  │      │←Home │   ← row 3
│Start │Stop  │Reset │      │      │      │      │      │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
```

## Button-by-button

### Row 0 — Status

| Pos | Label | Action | Feedback | Notes |
|-----|-------|--------|----------|-------|
| 0/0 | ProP | — | `propresenter_saitama:connected` → green `ProP ● OK` | |
| 0/1-6 | (blank) | — | — | Spacers |
| 0/7 | `$(internal:time_hms)` | — | — | Wall clock |

### Row 1 — Slide navigation

| Pos | Label | Press | Target | Notes |
|-----|-------|-------|--------|-------|
| 1/0 | PREV | `propresenter_saitama:prev_slide` | ProPresenter | **Note: action ID `prev_slide` may not exist** — verified module action is `last`. See TODO. |
| 1/1 | NEXT | `propresenter_saitama:next_slide` | ProPresenter | **Same** — verified is `next`. |
| 1/2 | GO | `propresenter_saitama:trigger_next` | ProPresenter | **Same** — verified is `next`. |
| 1/3 | (blank) | — | — | — |
| 1/4 | Slide 1 | `propresenter_saitama:trigger_slide {index: 0}` | ProPresenter | Likely should be `slideNumber {slide: 1}` |
| 1/5 | Slide 2 | `… {index: 1}` | ProPresenter | |
| 1/6 | Slide 3 | `… {index: 2}` | ProPresenter | |
| 1/7 | Slide 4 | `… {index: 3}` | ProPresenter | |

### Row 2 — Looks + clears

| Pos | Label | Press | Target | Notes |
|-----|-------|-------|--------|-------|
| 2/0 | Normal | `propresenter_saitama:trigger_look {name: Normal}` | ProPresenter | **Verified action is `pro7SetLook` with `pro7LookUUID`** — not `trigger_look`. See TODO. |
| 2/1 | Lyrics | `… {name: Lyrics}` | ProPresenter | |
| 2/2 | Scripture | `… {name: Scripture}` | ProPresenter | |
| 2/3 | Blank | `… {name: Blank}` | ProPresenter | |
| 2/4 | (blank) | — | — | — |
| 2/5 | CLEAR Slide | `propresenter_saitama:clear_slide` | ProPresenter | **Verified action is `clearslide`** (one word). |
| 2/6 | CLEAR Media | `propresenter_saitama:clear_media` | ProPresenter | **Verified actions: `clearbackground`, `clearaudio`** — `clear_media` is not a real action. |
| 2/7 | CLEAR All | `propresenter_saitama:clear_all` | ProPresenter | **Verified is `clearall`**. |

### Row 3 — Timers + nav

| Pos | Label | Press | Target | Notes |
|-----|-------|-------|--------|-------|
| 3/0 | Timer Start | `propresenter_saitama:timer_start {index: 0}` | ProPresenter | **Verified action is `clockStart {clockIndex: "0"}`**. |
| 3/1 | Timer Stop | `… timer_stop {index: 0}` | ProPresenter | **Verified is `clockStop`**. |
| 3/2 | Timer Reset | `… timer_reset {index: 0}` | ProPresenter | **Verified is `clockReset`**. |
| 3/3 | +1 Min | `… timer_adjust {index: 0, seconds: 60}` | ProPresenter | **No `timer_adjust` action** — would need `clockUpdate` with computed time. |
| 3/4 | −1 Min | `… {seconds: -60}` | ProPresenter | Same caveat. |
| 3/5 | Message | `… toggle_message {index: 0}` | ProPresenter | **Verified actions: `messageSend` / `messageHide`** — no toggle. |
| 3/6 | (blank) | — | — | — |
| 3/7 | ← Home | `internal:set_page {page: 40}` | Companion | |

## Connection dependencies

| Connection ID | Required for |
|---------------|--------------|
| `propresenter_saitama` | Everything except 3/7 nav |

## Known issues / TODOs

This page was designed against placeholder action IDs that **do not match the actual `renewedvision-propresenter` 3.0.2 module**. Cross-reference [action-ids.md](../reference/action-ids.md#renewedvision-propresenter) for the verified set.

| Yaml uses | Should be | Notes |
|-----------|-----------|-------|
| `prev_slide` | `last` | Row 1 |
| `next_slide` / `trigger_next` | `next` | Row 1 |
| `trigger_slide {index: N}` | `slideNumber {slide: N+1, path: …}` | Index → slide-number, +1 (slides are 1-indexed in module API) |
| `trigger_look {name}` | `pro7SetLook {pro7LookUUID}` | UUIDs are dynamic; selectable via Companion UI dropdown — hard-coding by name will not work |
| `clear_slide` | `clearslide` | One word |
| `clear_media` | `clearbackground` (or `clearaudio` for audio) | Module has no unified "media" clear |
| `clear_all` | `clearall` | One word |
| `timer_start` / `timer_stop` / `timer_reset` | `clockStart` / `clockStop` / `clockReset` | Use `clockIndex` not `index` |
| `timer_adjust` | (not supported) | Use `clockUpdate {clockIndex, clockTime}` with computed string |
| `toggle_message` | `messageSend` / `messageHide` | No toggle action |

**This page will not function correctly until these are corrected.** Page 40 (Home) uses the verified IDs (`last`, `next`, `clearslide`, `clockStart`, etc.) and works.

Once corrected, the look-by-name buttons will need a separate strategy: either (a) hard-code the UUIDs after first connection, (b) use a static look index and rely on operator memory, or (c) build a generator macro that resolves names → UUIDs at deploy time.

## Cross-references

- Parent: [Page 40 Home](saitama-xl-40-home.md)
- Sibling pages: [Page 41 Audio](saitama-xl-41-audio.md), [Page 43 Stream](saitama-xl-43-stream.md)
- Verified ProPresenter actions: [reference/action-ids.md](../reference/action-ids.md#renewedvision-propresenter)
- Module reference: [docs/companion/integrations/module-action-reference.md](../integrations/module-action-reference.md)
