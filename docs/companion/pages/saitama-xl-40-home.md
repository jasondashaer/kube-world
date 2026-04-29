# Page 40: Home Dashboard (Saitama / Stream Deck XL)

Source: `apps/companion/config/pages/saitama/xl-page01-home.yaml`

## Purpose

Top-level operations dashboard for the Saitama XL. Provides at-a-glance system health, slide control, OBS scene switching, audio mute/duck, service-state buttons, and navigation to the three subordinate pages (41 Audio, 42 ProP, 43 Stream). Designed so the worship-tech volunteer never needs to leave this page during a normal service.

8×4 grid (32 buttons, no encoders).

## Grid layout

```
┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────┐
│ ATEM │ OBS  │Audio │ ProP │      │      │ mode │ time │   ← row 0 status
│ ●OK  │ ●OK  │ ●OK  │ ●OK  │      │      │      │HH:MM │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│ PREV │ NEXT │  GO  │CLEAR │STREAM│ REC  │Intro │Outro │   ← row 1 slides+stream
│ 前へ │ 次へ │ 進む │クリア│ 配信 │ 録画 │      │      │
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│Timer │Timer │Timer │Worsh.│Speak.│Pastor│Master│ DUCK │   ← row 2 timers+audio
│ Strt │ Stop │Reset │ TBD  │ TBD  │MUTE  │MUTE  │ダック│
├──────┼──────┼──────┼──────┼──────┼──────┼──────┼──────┤
│Start │Shut  │      │      │→Audio│→ProP │→Strm │PANIC │   ← row 3 utils+nav
│ up   │ down │      │      │ 音響 │スライ│ 配信 │ 緊急 │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
```

## Button-by-button

### Row 0 — Status bar

| Pos | Label | Action | Feedback | Target | Notes |
|-----|-------|--------|----------|--------|-------|
| 0/0 | ATEM | — | `atem:connected` → green `ATEM ● OK` | ATEM | Connection placeholder — `atem` not in connections.yaml yet |
| 0/1 | OBS | — | `obs:connected` → green `OBS ● OK` | OBS | Same — `obs` not yet defined |
| 0/2 | Audio / 音響 | — | `yamaha_saitama:connected` → green `Audio ● OK` | Yamaha TF1 | |
| 0/3 | ProP | — | `propresenter_saitama:connected` → green `ProP ● OK` | ProPresenter | |
| 0/4-5 | (blank) | — | — | — | Spacers |
| 0/6 | `$(custom_service_mode)` | — | — | Companion | Live service-state display |
| 0/7 | `$(internal:time_hms)` | — | — | Companion | Wall clock |

### Row 1 — Slides + stream + intro/outro

| Pos | Label EN/JP | Press | Feedback | Target |
|-----|-------------|-------|----------|--------|
| 1/0 | PREV / 前へ | `propresenter_saitama:last` | — | ProPresenter |
| 1/1 | NEXT / 次へ | `propresenter_saitama:next` | — | ProPresenter |
| 1/2 | GO / 進む | `propresenter_saitama:next` | — | ProPresenter |
| 1/3 | CLEAR / クリア | `propresenter_saitama:clearslide` | — | ProPresenter |
| 1/4 | STREAM / 配信 | `obs:toggle_streaming` | `obs:streaming` → red `● LIVE 配信中` | OBS |
| 1/5 | REC / 録画 | `obs:toggle_recording` | `obs:recording` → red `● REC 録画中` | OBS |
| 1/6 | Intro / イントロ | `obs:set_current_scene {scene: Intro}` | `obs:scene_active {scene: Intro}` → green `● Intro` | OBS |
| 1/7 | Outro / アウトロ | `obs:set_current_scene {scene: Outro}` | `obs:scene_active {scene: Outro}` → green `● Outro` | OBS |

### Row 2 — Timers + scenes + audio

| Pos | Label EN/JP | Press | Feedback | Target | Notes |
|-----|-------------|-------|----------|--------|-------|
| 2/0 | Timer / 開始 | `propresenter_saitama:clockStart {clockIndex: "0"}` | — | ProPresenter | |
| 2/1 | Timer / 停止 | `propresenter_saitama:clockStop {clockIndex: "0"}` | — | ProPresenter | |
| 2/2 | Timer / リセット | `propresenter_saitama:clockReset {clockIndex: "0"}` | — | ProPresenter | |
| 2/3 | Worship 賛美 (TBD) | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:1, Y:1}` | — | Yamaha TF1 | TBD: confirm scene bank/slot |
| 2/4 | Speaking 説教 (TBD) | `yamaha_saitama:MIXER_Lib/Bank/Scene/Recall {X:1, Y:2}` | — | Yamaha TF1 | TBD: confirm scene bank/slot |
| 2/5 | Pastor / ミュート | `yamaha_saitama:MIXER_Current/InCh/Fader/On {X:11, Val:Toggle}` | `InCh/Fader/On {X:11, Val:0}` → red `MUTE / ミュート` | Yamaha TF1 | Pastor channel = 11 |
| 2/6 | Master / ミュート | `yamaha_saitama:MIXER_Current/St/Fader/On {X:1, Val:Toggle}` | `St/Fader/On {X:1, Val:0}` → red `MUTE / ミュート` | Yamaha TF1 | |
| 2/7 | DUCK / ダック | Step 0: 4-step fade ST 0→−2000; Step 1: reverse | — | Yamaha TF1 | Two-step toggle. Simpler than YIBC duck (no Mix17 offset). 4×100ms = 400ms |

### Row 3 — Utilities + navigation + safety

| Pos | Label EN/JP | Press | Notes |
|-----|-------------|-------|-------|
| 3/0 | Startup / 起動 | `internal:custom_variable_set_value {name: startup_phase, value: Starting}` | Triggers the "Service Start" trigger sequence (see triggers.yaml) |
| 3/1 | Shutdown / 終了 | Step 0: confirm; Step 1: (no destructive action, returns to step 0) | Two-step safety. Currently no shutdown action wired |
| 3/2 | (blank) | — | — |
| 3/3 | (blank) | — | — |
| 3/4 | → Audio / 音響 | `internal:set_page {page: 41}` | Jump to Audio Mixer |
| 3/5 | → ProP / スライド | `internal:set_page {page: 42}` | Jump to ProPresenter page |
| 3/6 | → Stream / 配信 | `internal:set_page {page: 43}` | Jump to Stream page |
| 3/7 | PANIC / 緊急 | Step 0: confirm; Step 1: `yamaha_saitama:MIXER_Current/St/Fader/On {X:1, Val:0}` (mute master) | Two-step safety to prevent accidental kill |

## Connection dependencies

| Connection ID | Required for |
|---------------|--------------|
| `yamaha_saitama` | Audio status, Pastor mute, Master mute, DUCK, Worship/Speaking scenes, PANIC |
| `propresenter_saitama` | ProP status, PREV/NEXT/GO/CLEAR, all timer buttons |
| `obs` (TBD) | OBS status, STREAM, REC, Intro/Outro scene buttons |
| `atem` (TBD) | ATEM status |

## Known issues / TODOs

- **TBD scenes** at 2/3 (Worship) and 2/4 (Speaking): the Yamaha scene bank/slot needs confirmation against the actual TF1 scene library. Banks are addressed `X = bank (1-100), Y = A(1)/B(2)`.
- **OBS / ATEM connections not yet defined** in `connections.yaml`. Status indicators will stay red until added.
- **Shutdown button is a placeholder** — confirm step does nothing. Either remove or wire to a real shutdown sequence (stop stream, save scene, etc.).
- **Service mode display** (0/6) shows `$(custom_service_mode)` — value is set by triggers (Idle / Ready / Starting / Pre-Service / Live / Closing / Off). See [triggers reference](../reference/triggers.md).

## Cross-references

- Subordinate pages: [Page 41 Audio](saitama-xl-41-audio.md), [Page 42 ProP](saitama-xl-42-prop.md), [Page 43 Stream](saitama-xl-43-stream.md)
- Triggers: [reference/triggers.md](../reference/triggers.md)
- Smooth fades: [reference/smooth-fades.md](../reference/smooth-fades.md)
