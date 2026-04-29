# Blackmagic ATEM — System Doc

> **Status: Saitama only, NOT YET CONFIGURED — placeholder.**
>
> No ATEM connection currently exists in `apps/companion/config/connections.yaml`. This doc captures the planned shape.

The ATEM at Saitama is used for **streaming output routing and recording** rather than as the primary live program switcher. Cameras are fixed; the ATEM lives in the signal chain to feed the streaming PC and (eventually) the hardware recorder. YIBC has no ATEM.

## Module

- Package: `bmd-atem`
- Version: TBD — confirm at install
- Protocol: ATEM proprietary (TCP/UDP)

## Planned Connection Config

```yaml
- id: atem_saitama
  module: "bmd-atem"
  label: "ATEM (Saitama)"
  enabled: true
  config:
    host: "TBD"
    # ATEM module typically auto-discovers model and capabilities once connected
```

## Role at Saitama

The ATEM is **not** what the Stream Deck operator uses to "switch cameras live" — that's not the workflow at Saitama. Instead:

- Inputs: camera feeds + slide capture from ProPresenter
- Program output → streaming PC (OBS) and/or hardware recorder
- DSK/keys/FTB used for graphics overlays and clean cut-to-black
- Macros may drive routing/recording presets

So the Companion buttons that target the ATEM will lean toward **routing and recording control**, not classic live-switching.

## Common Actions

| Action | `definitionId` | Notes |
|---|---|---|
| Auto transition | `auto_transition` | T-bar style |
| Cut transition | `cut_transition` | Hard cut |
| Toggle FTB | `toggle_ftb` | Fade-to-black |
| Set preview input | `set_preview_input` | Studio mode |
| Set program input | `set_program_input` | Direct to PGM |
| Toggle DSK | `toggle_dsk` | Downstream key on/off |
| Macro run | `run_macro` | Trigger ATEM macro |

Confirm exact action IDs against `bmd-atem` once installed.

## Common Feedbacks

| Feedback | Use |
|---|---|
| `connected` | Connection status indicator |
| `preview_tally` | Light preview-source button green |
| `program_tally` | Light program-source button red |
| `ftb_active` | Show FTB engaged |
| `dsk_on_air` | Show DSK live |
| `macro_running` | Highlight macro in progress |

## Variables

| Variable | Description |
|---|---|
| `program_input` | Active program input number/name |
| `preview_input` | Active preview input |
| `transition_position` | T-bar position |
| `time` | ATEM clock |
| `model` | Detected ATEM model |

## TODO

- [ ] Confirm ATEM model (Mini, Mini Pro, Television Studio, Constellation, etc.)
- [ ] Confirm static IP / hostname on the Saitama LAN
- [ ] Document input mapping: which physical input is which camera/slide source
- [ ] Define which routing macros (if any) Companion will trigger vs. operate the buttons directly
- [ ] Decide DSK strategy (always-on lower thirds vs. button-toggled)
- [ ] Add YAML page: a Saitama-only "Stream / Routing" page, likely the XL `xl-page04-stream.yaml`

## Related

- Module reference: [`../integrations/blackmagic-atem.md`](../integrations/blackmagic-atem.md)
- OBS (downstream of ATEM at Saitama): [`obs-studio.md`](obs-studio.md)
- Future hardware recorder: [`blackmagic-recorder.md`](blackmagic-recorder.md)
