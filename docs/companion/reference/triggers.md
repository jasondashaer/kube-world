# Triggers Reference

Companion triggers are event-condition-action rules that drive automation across connected systems. They are the orchestration layer that lets Companion act as a service-flow controller — a ProPresenter operator advances slides normally, and the triggers fire OBS scene changes, mixer fades, and stream control automatically.

Source: `apps/companion/config/triggers.yaml`

## Why Companion (not PP macros)?

ProPresenter macros are limited to PP-internal actions and a small set of network-link integrations. They cannot:

- Toggle OBS streaming
- Recall mixer scenes
- Trigger smooth multi-step audio fades
- Coordinate PP + OBS + mixer + camera in a single sequence

Companion sees all systems via its connection abstractions. Triggers in Companion can read any module's variable and dispatch any module's action. This makes Companion the **service-flow orchestrator** — PP becomes one input, not the conductor.

## Bidirectional pattern

Many triggers follow a "watch PP variable → take action" pattern:

```
PP video_countdown_timer hits 0:00
  → Companion trigger fires
    → OBS scene change
    → mixer scene recall
    → custom_service_mode = "Live"
```

This means the operator can drive Companion automation by manipulating PP — including starting a countdown, loading a presentation named "Closing", etc. PP becomes both a slide engine and a state controller.

---

## Trigger anatomy

```yaml
triggers:
  - name: "Human-readable name"
    enabled: true|false
    sort_order: <int>           # ordering when multiple match
    events:                     # what fires the trigger
      - type: <event_type>
        options: { ... }
    conditions:                 # additional gating (all must be true)
      - type: <feedback_id>
        options: { ... }
    actions:                    # ordered list, runs sequentially
      - action: <module:actionId>
        options: { ... }
```

### Event types

| Type | Options | Description |
|------|---------|-------------|
| `startup` | `delay` (ms) | Fires once when Companion starts, after delay |
| `interval` | `seconds` (int) | Fires repeatedly every N seconds |
| `condition_true` | (none) | Fires when all `conditions` become true (edge-triggered) |
| `button_press` | (button ref) | Fires when a specific button is pressed |
| `button_depress` | (button ref) | Fires on button release |
| `client_connect` | (none) | Fires when a Companion client (web UI / surface) connects |

### Common condition feedback types

| Type | Options | Description |
|------|---------|-------------|
| `internal:variable_value` | `variable` (`<connection>:<var>`), `value` | Match variable equals value |
| `<module>:<feedback_id>` | module-specific | Same as in feedbacks on buttons |

---

## Currently defined triggers

All non-system triggers ship `enabled: false` by default. Enable individually after testing in a non-live environment. Variable name strings must be confirmed against the actual PP instance via the Companion UI.

### System (always active)

| Sort | Name | Event | Action |
|------|------|-------|--------|
| 0 | Startup: Set service mode | `startup {delay: 5000}` | `service_mode = "Ready"` |

This is the only enabled trigger.

### Pre-service flow (disabled)

Driven by `ProPresenter:video_countdown_timer`. Operator starts a PP countdown in pre-service slides; triggers cascade.

| Sort | Name | Condition | Actions |
|------|------|-----------|---------|
| 10 | Pre-Service: Start stream at 1min | `video_countdown_timer == "00:01:00"` | `obs:toggle_streaming`; `service_mode = "Pre-Service"` |
| 11 | Pre-Service: Intro at 10sec | `video_countdown_timer == "00:00:10"` | `obs:set_current_scene {scene: Intro}` |
| 12 | Pre-Service: Go live at countdown end | `video_countdown_timer == "00:00:00"` | `obs:set_current_scene {scene: Camera}`; `obs:toggle_recording`; `service_mode = "Live"` |

### End-of-service flow (disabled)

Driven by detecting the closing presentation in PP.

| Sort | Name | Condition | Actions |
|------|------|-----------|---------|
| 20 | End: Detect closing presentation | `presentation_name == "Closing"` | `service_mode = "Closing"` |
| 21 | End: Duck audio on close | `service_mode == "Closing"` | 4-step duck of ST master + Mix17 |
| 22 | End: Outro scene after 10sec | `service_mode == "Closing"` | wait 10s → `obs:set_current_scene {scene: Outro}` |
| 23 | End: Stop stream after 20sec | `service_mode == "Closing"` | wait 20s → `obs:toggle_streaming`; `obs:toggle_recording`; `service_mode = "Off"` |

**Caveat**: triggers 22 and 23 are condition-based but use long `internal:wait` inside the action chain. If `service_mode` flips back during the wait, the action proceeds anyway. Better pattern: use `interval` event with elapsed-time check.

### Service start sequence (disabled)

Driven by the row 3/0 "Startup" button on Page 40, which sets `service_mode = "Starting"`.

| Sort | Name | Condition | Actions |
|------|------|-----------|---------|
| 30 | Start: Recall mixer scene | `service_mode == "Starting"` | `yamaha:MIXER_Lib/Bank/Scene/Recall {X:1, Y:1}`; wait 2s; `service_mode = "Pre-Service"` |

### Monitoring (commented out)

A future "Detect stream start" trigger pattern is shown commented in the YAML — fires when `obs:streaming` becomes true and updates `service_mode` accordingly. Useful as a sanity check.

---

## Service flow architecture

```
┌─────────────────────────────────────────────────────────┐
│                    PRE-SERVICE                          │
│   Operator runs PP countdown timer in pre-service slides│
│   Companion watches video_countdown_timer               │
└─────────────────────────────────────────────────────────┘
                         │
              T-1:00  ───┤── Start stream + service_mode="Pre-Service"
              T-0:10  ───┤── Switch to Intro scene
              T-0:00  ───┤── Switch to Camera + start record + "Live"
                         ▼
┌─────────────────────────────────────────────────────────┐
│                    DURING SERVICE                       │
│   PP slide ops drive presentation                       │
│   Operator can use Stream Deck for ad-hoc adjustments   │
│   No automation triggers fire (service_mode = "Live")   │
└─────────────────────────────────────────────────────────┘
                         │
              PP loads "Closing"  ─── service_mode = "Closing"
                         ▼
┌─────────────────────────────────────────────────────────┐
│                    END-OF-SERVICE                       │
│   service_mode = "Closing" cascades:                    │
└─────────────────────────────────────────────────────────┘
              0s    ── audio duck (4-step fade)
              +10s  ── Outro scene
              +20s  ── Stop stream + record + service_mode="Off"
```

---

## Enabling triggers safely

1. **Confirm variable names**: open Companion web UI → Connections → ProPresenter → Variables. Verify `video_countdown_timer` exists with that exact name.
2. **Confirm presentation name**: load the closing presentation, check what `presentation_name` returns.
3. **Confirm scene names**: check OBS scene collection for exact case-sensitive names ("Intro", "Outro", "Camera").
4. **Confirm Yamaha scene**: identify the actual scene bank/slot for "service start".
5. **Test individually**: enable ONE trigger, run a service rehearsal, observe.
6. **Commit through git**: edit `triggers.yaml`, set `enabled: true`, commit, push. Do NOT toggle in the web UI — Karmada will revert.

---

## Trigger limitations

- **`condition_true` is edge-triggered**: fires once when conditions transition false → true. Will not fire again until they go false then true again.
- **Long `internal:wait` blocks the trigger queue**: while a wait is running, no new triggers fire. Use sparingly.
- **No "else" clause**: if you need bidirectional state machines, use multiple triggers with mirror conditions.
- **String comparison is exact**: `video_countdown_timer` could format as `"00:01:00"` or `"01:00"` depending on PP version. Test the actual format.

---

## Cross-references

- Source YAML: `apps/companion/config/triggers.yaml`
- ProPresenter variables that triggers can watch: [variables.md](variables.md#propresenter-variables)
- Action IDs available to triggers: [action-ids.md](action-ids.md)
- Service flow references in pages: [Page 40 Home](../pages/saitama-xl-40-home.md) (Startup button)
- Smooth fade pattern (used in End: Duck): [smooth-fades.md](smooth-fades.md)
