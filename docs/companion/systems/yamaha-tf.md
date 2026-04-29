# Yamaha TF Series — System Doc

Yamaha TF digital mixers at both church locations, driven via Yamaha RCP over TCP. This page documents the **deployed** systems; for the full module API surface (200+ actions/feedbacks/variables) see [`../integrations/yamaha-tf.md`](../integrations/yamaha-tf.md).

| Field | YIBC | Saitama |
|---|---|---|
| Model | TF5 (32 channel) | TF1 (16 channel) |
| Host | `192.168.1.54` | `192.168.10.30` |
| Connection ID | `yamaha_yibc` | `yamaha_saitama` |
| Label | `Yamaha TF5 (YIBC)` | `Yamaha TF1 (Saitama)` |
| Pages that use it | Plus ops, MK2 ops | XL audio (page 02) |

## Module

- Package: `yamaha-rcp`
- Version: **3.5.10**
- Protocol: Yamaha RCP over TCP

## Connection Config

Both connections use the same shape; only `host` differs.

```yaml
- id: yamaha_yibc            # or yamaha_saitama
  module: "yamaha-rcp"
  label: "Yamaha TF5 (YIBC)" # or "Yamaha TF1 (Saitama)"
  enabled: true
  config:
    host: "192.168.1.54"     # or 192.168.10.30
    model: "TF"              # string, NOT a number
```

**Critical generator flags** (added by `companion-deploy.py`, do not omit):

| Flag | Value | Why |
|---|---|---|
| `isFirstInit` | `true` | Skips upgrade scripts (`upg2xxto30x`) that crash with `findRcpCmd undefined` on a fresh import. |
| `model` | `"TF"` | Must be the literal string from the dropdown set (`CL/QL`, `PM`, `TF`, `DM3`, `DM7`, `RIO`, `TIO`, `RSIO`). |
| `lastUpgradeIndex` | latest | Set by generator. |

## Action ID Format

RCP-style addresses with `/` separators. `definitionId` is what the import format expects; the UI export labels them `actionId`.

| Action | `definitionId` | Options |
|---|---|---|
| Channel mute | `MIXER_Current/InCh/Fader/On` | `X`=ch#, `Val`=0/1/Toggle |
| Channel level | `MIXER_Current/InCh/Fader/Level` | `X`=ch#, `Val`=-32768..1000, optional `Rel: true` |
| Stereo master mute | `MIXER_Current/St/Fader/On` | `X`=1, `Val`=0/1/Toggle |
| Stereo master level | `MIXER_Current/St/Fader/Level` | `X`=1, `Val`=-32768..1000 |
| Aux/Mix bus mute | `MIXER_Current/Mix/Fader/On` | `X`=bus#, `Val`=0/1/Toggle |
| Aux/Mix bus level | `MIXER_Current/Mix/Fader/Level` | `X`=bus#, `Val`=-32768..1000 |
| DCA mute | `MIXER_Current/DCA/Fader/On` | `X`=DCA#, `Val`=0/1/Toggle |
| DCA level | `MIXER_Current/DCA/Fader/Level` | `X`=DCA#, `Val`=-32768..1000 |
| Scene recall (TF) | `MIXER_Lib/Bank/Scene/Recall` | `X`=bank#, `Y`=1 (A) or 2 (B) |

### Mute Logic — Inverted

`Fader/On` semantically means "on", not "muted":

| `Val` | Meaning |
|---|---|
| `1` | ON (unmuted) |
| `0` | MUTED |
| `"Toggle"` | flip state |

It's easy to invert this by accident — the action is named `Fader/On`, not `Mute`.

### Fader Scale

Linear units, **100 units = 1 dB**.

| `Val` | dB |
|---|---|
| `-32768` | -∞ (silence) |
| `-2000` | -20 dB |
| `-600` | -6 dB |
| `0` | 0 dB (unity) |
| `1000` | +10 dB (max) |

### Relative Faders

Add `Rel: true` to the options to send a delta instead of an absolute value. Useful for nudge buttons:

```yaml
- definitionId: "MIXER_Current/InCh/Fader/Level"
  options: { X: 1, Val: 100, Rel: true }   # +1 dB nudge
```

## Smooth Fade Pattern

The TF RCP protocol has **no native fade duration**. Smooth fades are done in software as a sequence of level commands separated by `internal:wait`. See [`../reference/smooth-fades.md`](../reference/smooth-fades.md) for the full pattern; quick summary:

- 20 steps × 50 ms = ~1 s fade
- Each step: set level + (optionally set offset bus) + `internal:wait`
- For multi-bus fades, maintain dB offset by computing `aux_val = master_val + offset_units` (e.g. aux at -6 dB → `offset_units = -600`)

Live example: YIBC MK2 "duck" button, `pages/yibc/mk2-page01-ops.yaml`.

## Channel Maps

### TF1 (Saitama) — known channels

| Ch | Source | Notes |
|---|---|---|
| 1 | Worship leader mic | |
| 4 | Guitar | |
| 6 | Keys | |
| 11 | Pastor mic | |
| 14 | Media playback | |

### TF5 (YIBC) — TBD

Channel map to be filled in once the live config audit is done. Probable layout follows the same pastor / worship / band / media pattern.

## Common Button Patterns

### Channel mute toggle

```yaml
- type: "button"
  text: "Pastor"
  actions:
    down:
      - type: "action"
        definitionId: "MIXER_Current/InCh/Fader/On"
        options: { X: 11, Val: "Toggle" }
```

### Scene recall (Sunday morning)

```yaml
- type: "button"
  text: "Sunday AM"
  actions:
    down:
      - type: "action"
        definitionId: "MIXER_Lib/Bank/Scene/Recall"
        options: { X: 1, Y: 1 }
```

### Fader nudge (+1 dB)

```yaml
- type: "button"
  text: "Vox +1"
  actions:
    down:
      - type: "action"
        definitionId: "MIXER_Current/InCh/Fader/Level"
        options: { X: 11, Val: 100, Rel: true }
```

## Variables Exposed

| Variable | Description |
|---|---|
| `$(Yamaha_TF5:modelName)` | Device model string |
| `$(Yamaha_TF5:curScene)` | Current scene ID (e.g. `B08`) |
| `$(Yamaha_TF5:curSceneName)` | Current scene name |
| `$(Yamaha_TF5:runMode)` | Device run mode |
| `$(Yamaha_TF5:error)` | Last error reported by RCP |

Variable prefix is the **connection label** with spaces/parens normalised, e.g. `Yamaha_TF5` for `Yamaha TF5 (YIBC)`. The TF1 Saitama prefix is `Yamaha_TF1`. Additional auto-create variables appear once feedbacks register them.

## Known Issues

- **None currently.** The early upgrade-script crash (`findRcpCmd undefined`) is fixed by `isFirstInit: true` in the generator. If you ever see it again, check that flag is being emitted.
- When the Pi switches networks (LAN at YIBC vs. Saitama), only one of the two connections will be reachable. The other shows disconnected. This is by design.

## Related

- Full module API surface: [`../integrations/yamaha-tf.md`](../integrations/yamaha-tf.md)
- Smooth fade reference: [`../reference/smooth-fades.md`](../reference/smooth-fades.md)
- Connection source: `apps/companion/config/connections.yaml`
- Pages: `apps/companion/config/pages/yibc/mk2-page01-ops.yaml`, `pages/saitama/xl-page02-audio.yaml`
