# Smooth Audio Fades

The Yamaha TF series RCP protocol has no native fade-duration parameter. `Fader/Level` is an instantaneous set — write a value, fader jumps. To produce audible smooth fades for ducking, intro/outro transitions, etc., we synthesize them as a sequence of small fader changes separated by `internal:wait`.

This document covers the design, parameters, and tradeoffs.

## Why software fades

Possible alternatives considered and rejected:

| Approach | Why rejected |
|----------|--------------|
| Yamaha scene recall with ramp time | TF scenes ramp at a fixed rate set on the mixer; not per-fade configurable |
| TF "Send" with macro | Macros require physical user keys, not RCP commands |
| QSC AmpLink / Dante audio routing fade | Out of scope — different system |
| Built-in PP audio fade | Only works for PP-managed audio playback, not main FOH bus |

Software fades via Companion's action chain are the lowest-friction option that gives per-fade control of duration, depth, and curve.

## Pattern

```yaml
actions:
  down:
    - action: yamaha:MIXER_Current/St/Fader/Level
      options: { X: 1, Val: -100 }
    - action: internal:wait
      options: { time: "50" }
    - action: yamaha:MIXER_Current/St/Fader/Level
      options: { X: 1, Val: -200 }
    - action: internal:wait
      options: { time: "50" }
    # ... N more steps ...
    - action: yamaha:MIXER_Current/St/Fader/Level
      options: { X: 1, Val: -2000 }
```

Each step is a single fader value plus a wait. Companion executes them strictly in order — fader hits −100, waits 50ms, hits −200, etc.

## Parameter dimensions

| Parameter | Effect | Tradeoff |
|-----------|--------|----------|
| **Step count** | More steps = smoother audible fade | More YAML, larger import payload |
| **Step interval (wait time)** | Shorter wait = faster fade | Wait shorter than ~30ms loses smoothness due to network/RCP latency |
| **Step depth (dB per step)** | Smaller delta = smoother | Determined by step count and total range |
| **Total duration** | Step count × wait time | UX preference: 400ms-1s typical |

### YIBC duck (button 2/1, page 30)

| Setting | Value |
|---------|-------|
| Total range | 0 to −2000 (0dB → −20dB) |
| Steps | 20 |
| Wait per step | 50ms |
| Total duration | **1000ms (1 sec)** |
| Step depth | 1dB |

Fade is on TWO buses simultaneously (stereo master + Mix17 front-fill) maintaining a fixed −6dB offset. Aux value = master + offset_in_units (offset = −600 since 100 units = 1dB).

### Saitama duck (button 2/7, page 40)

| Setting | Value |
|---------|-------|
| Total range | 0 to −2000 |
| Steps | 4 |
| Wait per step | 100ms |
| Total duration | **400ms** |
| Step depth | 5dB |

Faster, less smooth. Works because there's no Mix17 front-fill bus to coordinate at Saitama yet.

## Multi-bus offset

When fading multiple buses that should track each other (master + aux), maintain the dB offset throughout:

```
master_value:  0    →  -100  →  -200  →  ...  →  -2000
aux_value:    -600  →  -700  →  -800  →  ...  →  -2600
                ^                                    ^
                └─── -6dB offset preserved ─────────┘
```

Yamaha fader units: 100 units = 1dB in the linear range. So a −6dB offset is **−600 units**. Aux value = master_value + (−600).

### Example (YIBC duck step at master = -1000):

```yaml
- action: yamaha_yibc:MIXER_Current/St/Fader/Level
  options: { X: 1, Val: -1000 }       # master at -10dB
- action: yamaha_yibc:MIXER_Current/Mix/Fader/Level
  options: { X: 17, Val: -1600 }      # aux at -16dB (master - 6dB)
```

Both commands are dispatched in the same step (no wait between them) — Companion sends them back-to-back at maximum RCP rate, so they arrive within ~5ms. Audibly simultaneous.

## Linear vs logarithmic

Fader values −2000 to 0 are approximately **linear in dB** — i.e. equal-unit steps produce equal-dB steps. This makes a linear-step fade sound roughly logarithmic in amplitude (perceptually correct for "smooth" fades).

At the extremes the scale is non-linear:
- Below −2000 (down to −32768 = −∞): unit deltas have decreasing dB impact (very steep at bottom)
- Above 0 (up to +1000): unit deltas amplify

For typical duck fades (0 to −20dB), stay in the linear region. If you need to fade to −∞, do most of the fade linearly to −2000, then a single jump to −32768.

## Why two-step toggles (DUCK / UNDUCK)

Companion's `steps` mechanism lets a single button alternate between two action sets. We use this so DUCK and UNDUCK live on the same physical button:

- Step 0 (DUCK): fade down sequence + `internal:step_delta {amount: 1}` advances to step 1.
- Step 1 (UNDUCK): fade up sequence + `internal:step_delta {amount: -1}` returns to step 0.

The `step_delta` MUST be the last action in each step's chain — if it runs first, the next press would be evaluated against the new step before the fade completes (probably fine because press is async, but order matters for some Companion versions).

## Limitations

- **Cannot interrupt mid-fade**: pressing DUCK during a UNDUCK in progress queues the new fade after the current one finishes. There's no built-in cancel mechanism.
- **Network latency adds drift**: each `Fader/Level` is a separate UDP round-trip to the mixer. On a busy LAN, steps can stretch slightly. 50ms is the lower bound that still feels smooth.
- **No per-channel timing**: all buses in a multi-bus fade step run simultaneously. If you want one bus to lead by, say, 100ms, you'd need to interleave with extra `internal:wait`.

## Future improvements

- Generator macro to expand a high-level `fade_to {channel, target, duration}` into the right step sequence at deploy time.
- Use `internal:custom_variable_set_expression` to compute fade values dynamically based on a stored pre-fade level (the `pre_duck_level` variable already exists in `variables.yaml` for this purpose but isn't wired).
- Support exponential / S-curve shapes by varying step depths.

## Cross-references

- YIBC duck (full 20-step example): [page 30 doc](../pages/yibc-mk2-30-ops.md#smooth-fade-duck-button-21)
- Saitama duck (4-step example): [page 40 doc](../pages/saitama-xl-40-home.md)
- Trigger that uses fade pattern: [triggers.md](triggers.md) (End: Duck audio on close)
- Yamaha fader value scale: [action-ids.md](action-ids.md#fader-value-scale)
