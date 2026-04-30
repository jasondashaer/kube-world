# Page 40: Home Dashboard (Saitama / Stream Deck XL)

Source: `apps/companion/config/pages/saitama/xl-page01-home.yaml`

## Purpose

Top-level operations dashboard for the Saitama XL. Provides at-a-glance system health, slide control, OBS scene switching, audio mute/duck, service-state buttons, and navigation to the four subordinate pages (41 Audio, 42 ProP, 43 Stream, 44 Segments). Designed so the worship-tech volunteer never needs to leave this page during a normal service.

8×4 grid (32 buttons, no encoders).

## Page summary

| Field | Value |
|-------|-------|
| Page number | 40 |
| Name | Home |
| Device | Stream Deck XL (8×4) |
| Source YAML | `apps/companion/config/pages/saitama/xl-page01-home.yaml` |
| Sibling pages | [41 Audio](saitama-xl-41-audio.md), [42 ProP](saitama-xl-42-prop.md), [43 Stream](saitama-xl-43-stream.md), [44 Segments](saitama-xl-44-segments.md) |
| Mixer connection | `yamaha_saitama` (Yamaha TF1 at `192.168.10.30`) |
| Slide connection | `propresenter_saitama` (`192.168.68.55:53678`) |
| Stream connection | `obs_saitama` (placeholder credentials) |
| Switcher connection | `atem_saitama` (placeholder credentials) |

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
│Start │Shut  │      │→Segm.│→Audio│→ProP │→Strm │PANIC │   ← row 3 utils+nav
│ up   │ down │      │ 場面 │ 音響 │スライ│ 配信 │ 緊急 │
└──────┴──────┴──────┴──────┴──────┴──────┴──────┴──────┘
```

## Button-by-button

### Row 0 — Status bar

| Pos | Label | Action | Feedback | Target | Notes |
|-----|-------|--------|----------|--------|-------|
| 0/0 | ATEM | — | `atem:connected` → green `ATEM ● OK` | ATEM | `atem_saitama` connection (enabled placeholder credentials) |
| 0/1 | OBS | — | `obs:connected` → green `OBS ● OK` | OBS | `obs_saitama` connection (enabled placeholder credentials) |
| 0/2 | Audio / 音響 | — | `yamaha_saitama:connected` → green `Audio ● OK` | Yamaha TF1 | |
| 0/3 | ProP | — | `propresenter_saitama:connected` → green `ProP ● OK` | ProPresenter | |
| 0/4-5 | (blank) | — | — | — | Spacers |
| 0/6 | `$(internal:custom_service_mode)` | — | — | Companion | Live service-state display |
| 0/7 | `$(internal:time_hms)` | — | — | Companion | Wall clock |

### Row 1 — Slides + stream + intro/outro

| Pos | Label EN/JP | Press | Feedback | Target |
|-----|-------------|-------|----------|--------|
| 1/0 | PREV / 前へ | `propresenter_saitama:last` | — | ProPresenter |
| 1/1 | NEXT / 次へ | `propresenter_saitama:next` | — | ProPresenter |
| 1/2 | GO / 進む | `propresenter_saitama:next` | — | ProPresenter |
| 1/3 | CLEAR / クリア | `propresenter_saitama:clearslide` | — | ProPresenter |
| 1/4 | STREAM / 配信 | `obs_saitama:toggle_streaming` | `obs_saitama:streaming` → red `● LIVE 配信中` | OBS |
| 1/5 | REC / 録画 | `obs_saitama:toggle_recording` | `obs_saitama:recording` → red `● REC 録画中` | OBS |
| 1/6 | Intro / イントロ | `obs_saitama:set_current_scene {scene: Intro}` | `obs_saitama:scene_active {scene: Intro}` → green `● Intro` | OBS |
| 1/7 | Outro / アウトロ | `obs_saitama:set_current_scene {scene: Outro}` | `obs_saitama:scene_active {scene: Outro}` → green `● Outro` | OBS |

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
| 3/0 | Startup / 起動 | `internal:custom_variable_set_value {name: startup_phase, value: Starting}` | Triggers the "Service Start" trigger sequence (see [reference/triggers.md](../reference/triggers.md)) |
| 3/1 | Shutdown / 終了 | Step 0: confirm; Step 1: (no destructive action, returns to step 0) | Two-step safety. Currently no shutdown action wired |
| 3/2 | (blank) | — | — |
| 3/3 | → Segments / 場面 | `internal:set_page {page: 44}` | Jump to [Page 44 Segments](saitama-xl-44-segments.md) |
| 3/4 | → Audio / 音響 | `internal:set_page {page: 41}` | Jump to [Page 41 Audio](saitama-xl-41-audio.md) |
| 3/5 | → ProP / スライド | `internal:set_page {page: 42}` | Jump to [Page 42 ProP](saitama-xl-42-prop.md) |
| 3/6 | → Stream / 配信 | `internal:set_page {page: 43}` | Jump to [Page 43 Stream](saitama-xl-43-stream.md) |
| 3/7 | PANIC / 緊急 | Step 0: confirm; Step 1: `yamaha_saitama:MIXER_Current/St/Fader/On {X:1, Val:0}` (mute master) | Two-step safety to prevent accidental kill |

## Connection dependencies

| Connection ID | Required for | Status |
|---------------|--------------|--------|
| `yamaha_saitama` | Audio status, Pastor mute, Master mute, DUCK, Worship/Speaking scenes, PANIC | Live (TF1 `192.168.10.30`) |
| `propresenter_saitama` | ProP status, PREV/NEXT/GO/CLEAR, all timer buttons | Live (`192.168.68.55:53678`) |
| `obs_saitama` | OBS status, STREAM, REC, Intro/Outro scene buttons | Enabled with **placeholder credentials** — activates when env values fill in |
| `atem_saitama` | ATEM status indicator | Enabled with **placeholder credentials** — activates when env values fill in |

The `obs_saitama` and `atem_saitama` connections exist in `connections.yaml` and are enabled, but ship with placeholder host/password values. They will go green (`● OK`) once real credentials are seeded — see [guides/secrets-and-credentials.md](../guides/secrets-and-credentials.md).

## Encoder configuration

N/A — XL has no encoders.

## Variables referenced

| Variable | Set by | Read by |
|----------|--------|---------|
| `service_mode` | Triggers (and YIBC ops page) | Status pad 0/6 |
| `startup_phase` | Startup button 3/0 | "Service Start" trigger (see [reference/triggers.md](../reference/triggers.md)) |
| `internal:time_hms` | Companion built-in | Wall clock 0/7 |

## Live-test plan

For each button, see the matching step in [guides/live-test-runbook.md](../guides/live-test-runbook.md):

- Status row — connection indicators flip green when each integration is reachable; `obs_saitama` and `atem_saitama` will be red until placeholder credentials are replaced.
- Slide row — PREV/NEXT/GO/CLEAR drive ProPresenter on `192.168.68.55`.
- STREAM / REC / Intro / Outro — exercise OBS toggles and scene recalls; verify scene names match OBS profile.
- Timer row — clock 0 start/stop/reset reflected in ProPresenter timer display.
- Worship / Speaking — TBD scene numbers; confirm against TF1 scene library before wiring as live-show paths.
- Pastor / Master mute — feedback flips red when fader off.
- DUCK / UNDUCK — verify 400ms fade-down, mix balance preserved on the way back up.
- Startup — confirm `startup_phase` advances and the linked trigger fires.
- Shutdown / PANIC — exercise the two-step confirm pattern; PANIC actually kills the master.
- Nav row (3/3–3/6) — confirms each page loads without surface re-bind.

## Known issues / TODOs

- **TBD scenes** at 2/3 (Worship) and 2/4 (Speaking): the Yamaha scene bank/slot needs confirmation against the actual TF1 scene library. Banks are addressed `X = bank (1-100), Y = A(1)/B(2)`.
- **`obs_saitama` / `atem_saitama` placeholder credentials**: connections enabled but won't connect until real host/password are populated — see [guides/secrets-and-credentials.md](../guides/secrets-and-credentials.md).
- **Shutdown button is a placeholder** — confirm step does nothing. Either remove or wire to a real shutdown sequence (stop stream, save scene, etc.).
- **Service mode display** (0/6) shows `$(internal:custom_service_mode)` — value is set by triggers (Idle / Ready / Starting / Pre-Service / Live / Closing / Off). See [reference/triggers.md](../reference/triggers.md).

## Cross-references

- Source YAML: [`apps/companion/config/pages/saitama/xl-page01-home.yaml`](../../../apps/companion/config/pages/saitama/xl-page01-home.yaml)
- Sibling pages on this surface: [41 Audio](saitama-xl-41-audio.md), [42 ProP](saitama-xl-42-prop.md), [43 Stream](saitama-xl-43-stream.md), [44 Segments](saitama-xl-44-segments.md)
- Triggers (startup_phase, service_mode chain): [reference/triggers.md](../reference/triggers.md)
- Scene strategy (Worship / Speaking / Segments context): [guides/scene-strategy.md](../guides/scene-strategy.md)
- OBS / ATEM placeholder credentials: [guides/secrets-and-credentials.md](../guides/secrets-and-credentials.md)
- Yamaha RCP namespace: [reference/yamaha-rcp-namespace.md](../reference/yamaha-rcp-namespace.md)
- Live-test plan for these buttons: [guides/live-test-runbook.md](../guides/live-test-runbook.md)
- Smooth fades design: [reference/smooth-fades.md](../reference/smooth-fades.md)
- Connection IDs: [reference/connection-ids.md](../reference/connection-ids.md)
- Companion subsystem conventions: [`apps/companion/CLAUDE.md`](../../../apps/companion/CLAUDE.md)
