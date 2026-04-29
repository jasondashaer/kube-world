# Page 41: Audio Mixer (Saitama / Stream Deck XL)

Source: `apps/companion/config/pages/saitama/xl-page02-audio.yaml`

## Purpose

Channel-strip-style mixer control for the Yamaha TF1 at Saitama. Provides per-channel mute toggles, ±1dB fader nudge buttons, scene recalls, and master 0dB / −∞ shortcuts. Designed for quick mid-service adjustments without leaving the Stream Deck for the physical mixer.

8×4 grid.

## Channel mapping (Saitama TF1)

| Channel ID | Yamaha X | Role |
|------------|----------|------|
| Pastor | 11 | Lapel mic |
| Worship | 1 | Worship leader vocal |
| Keys | 6 | Keyboard |
| Guitar | 4 | Acoustic guitar DI |
| Media | 14 | Media player return |
| Master (St) | 1 | Stereo master |

## Grid layout

```
┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│Pastor│Worsh.│ Keys │Guitar│Media │      │      │MASTER│   ← row 0 labels
│ 牧師 │ 賛美 │ 鍵盤 │ギター│メディ│      │      │マスター│
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│Pastor│Worsh.│ Keys │Guitar│Media │      │      │MASTER│   ← row 1 mute toggles
│ ●ON  │ ●ON  │ ●ON  │ ●ON  │ ●ON  │      │      │ ●ON  │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│Past ▲│Past ▼│Wors ▲│Wors ▼│Med ▲ │Med ▼ │Mast ▲│Mast ▼│   ← row 2 fader nudge
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│Sc 1  │Sc 2  │Sc 3  │Sc 4  │Mast  │Mast  │      │←Home │   ← row 3 scenes+nav
│      │      │      │      │ 0dB  │ -∞   │      │      │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
```

## Button-by-button

### Row 0 — Channel labels (display-only)

| Pos | Label EN/JP | Notes |
|-----|-------------|-------|
| 0/0 | Pastor / 牧師 | Maroon-purple bgcolor `#333366` |
| 0/1 | Worship / 賛美 | |
| 0/2 | Keys / 鍵盤 | |
| 0/3 | Guitar / ギター | |
| 0/4 | Media / メディア | Green-tint `#336633` to distinguish playback source |
| 0/5-6 | (blank) | Spacers |
| 0/7 | MASTER / マスター | Red-tint `#663333` |

### Row 1 — Mute toggles

| Pos | Label EN/JP | Press | Feedback (when muted) | Target |
|-----|-------------|-------|------------------------|--------|
| 1/0 | Pastor / 牧師 | `yamaha_saitama:MIXER_Current/InCh/Fader/On {X:11, Val:Toggle}` | red `MUTE` | TF1 ch 11 |
| 1/1 | Worship / 賛美 | `… {X:1, Val:Toggle}` | red `MUTE` | TF1 ch 1 |
| 1/2 | Keys / 鍵盤 | `… {X:6, Val:Toggle}` | red `MUTE` | TF1 ch 6 |
| 1/3 | Guitar / ギター | `… {X:4, Val:Toggle}` | red `MUTE` | TF1 ch 4 |
| 1/4 | Media / メディア | `… {X:14, Val:Toggle}` | red `MUTE` | TF1 ch 14 |
| 1/5-6 | (blank) | — | — | — |
| 1/7 | MASTER / マスター | `MIXER_Current/St/Fader/On {X:1, Val:Toggle}` | red `MUTE` | TF1 stereo master |

Default unmuted bgcolor: green `#00AA00`. Feedback `Val: 0` matches when channel is muted (Yamaha mute logic: Val=0 means muted, see [action-ids reference](../reference/action-ids.md#yamaha-rcp)).

### Row 2 — Fader nudge (±1dB = ±100 units)

| Pos | Label | Press | Target | Notes |
|-----|-------|-------|--------|-------|
| 2/0 | Pastor ▲ | `MIXER_Current/InCh/Fader/Level {X:11, Val:100, Rel:true}` | TF1 ch 11 | Relative +100 = +1dB |
| 2/1 | Pastor ▼ | `… {X:11, Val:-100, Rel:true}` | TF1 ch 11 | |
| 2/2 | Worship ▲ | `… {X:1, Val:100, Rel:true}` | TF1 ch 1 | |
| 2/3 | Worship ▼ | `… {X:1, Val:-100, Rel:true}` | TF1 ch 1 | |
| 2/4 | Media ▲ | `… {X:14, Val:100, Rel:true}` | TF1 ch 14 | |
| 2/5 | Media ▼ | `… {X:14, Val:-100, Rel:true}` | TF1 ch 14 | |
| 2/6 | Master ▲ | `MIXER_Current/St/Fader/Level {X:1, Val:100, Rel:true}` | TF1 master | |
| 2/7 | Master ▼ | `… {X:1, Val:-100, Rel:true}` | TF1 master | |

The `Rel: true` option makes Val a delta rather than an absolute. Note Keys (X=6) and Guitar (X=4) do not have nudge buttons in this layout — only labeled mute toggles. Reserved row 2 cols 4-5 for Media instead.

### Row 3 — Scene recalls + master shortcuts + nav

| Pos | Label | Press | Target | Notes |
|-----|-------|-------|--------|-------|
| 3/0 | Scene 1 | `MIXER_Lib/Bank/Scene/Recall {X:1, Y:1}` | TF1 | Bank 1, slot A |
| 3/1 | Scene 2 | `… {X:1, Y:2}` | TF1 | Bank 1, slot B |
| 3/2 | Scene 3 | `… {X:2, Y:1}` | TF1 | Bank 2, slot A |
| 3/3 | Scene 4 | `… {X:2, Y:2}` | TF1 | Bank 2, slot B |
| 3/4 | Master 0dB | `MIXER_Current/St/Fader/Level {X:1, Val:0}` | TF1 master | Snap to unity gain |
| 3/5 | Master −∞ | `… {X:1, Val:-32768}` | TF1 master | Hard mute via fader (not unmute-toggle) |
| 3/6 | (blank) | — | — | — |
| 3/7 | ← Home / ホーム | `internal:set_page {page: 40}` | Companion | |

## Connection dependencies

| Connection ID | Required for |
|---------------|--------------|
| `yamaha_saitama` | Every action and feedback on this page (except nav button) |

## Known issues / TODOs

- **No fader nudge for Keys / Guitar** — labels exist but nudge cells are reserved for Media. Consider adding either at the cost of removing Media nudge or shrinking the spacer columns.
- **Master −∞ vs Master MUTE distinction**: 1/7 is a mute toggle (uses `Fader/On`), 3/5 is a fader-to-zero (uses `Fader/Level`). They produce different states the mixer can recover from differently. Pick one based on operational preference.
- **Scene labels generic**: Scene 1-4 should be renamed to match actual TF1 scene library (e.g. "Worship", "Sermon", "Quiet", "Exit").
- **Channel assignments are Saitama-specific**: do not copy this page to YIBC without updating X values. YIBC TF5 has different channel assignments.

## Cross-references

- Parent: [Page 40 Home](saitama-xl-40-home.md)
- Sibling pages: [Page 42 ProP](saitama-xl-42-prop.md), [Page 43 Stream](saitama-xl-43-stream.md)
- Yamaha action IDs: [reference/action-ids.md](../reference/action-ids.md#yamaha-rcp)
