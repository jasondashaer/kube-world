# Blackmagic Recorder — System Doc

> **Status: PLACEHOLDER — Saitama future. Not currently deployed.**
>
> No connection exists yet. This doc reserves the slot.

Plan: replace OBS-based software recording at Saitama with a **hardware Blackmagic recorder** for reliability. Software recording on a streaming PC trades reliability for flexibility; for the archival recording of Sunday services we'd rather have a dedicated box that can't be killed by a Windows update or a CPU spike.

YIBC has no plans for a hardware recorder at this time.

## Probable Module

- Package: `bmd-hyperdeck` (most likely)
- Alternatives if hardware choice changes:
  - `bmd-videohub` — for routing matrices
  - A custom Web Presenter / Atem Mini Pro recording-control mapping

> Final module is contingent on hardware selection. HyperDeck is the assumed default because it's the most common Blackmagic standalone recorder with first-class Companion support.

## Likely Hardware Candidates

| Device | Notes |
|---|---|
| HyperDeck Studio HD Mini | Cheap, SD card-based, ProRes. Likely choice. |
| HyperDeck Studio HD Plus | Larger storage, multiple slots. |
| HyperDeck Studio 4K Pro | Overkill for a service archive. |
| ATEM Mini Pro ISO recording | Already in the chain if an ATEM Pro is used — could record without a separate box. |

If the existing/planned ATEM at Saitama is a Pro/ISO model, the simplest path is to use its built-in record feature controlled via `bmd-atem` rather than adding a separate HyperDeck.

## Planned Connection Config

```yaml
# Placeholder — adjust once hardware is chosen
- id: recorder_saitama
  module: "bmd-hyperdeck"
  label: "Recorder (Saitama)"
  enabled: true
  config:
    host: "TBD"
    # HyperDeck typically uses control protocol over TCP on 9993
```

## Likely Actions

| Action | Purpose |
|---|---|
| Record | Begin recording to selected slot |
| Stop | Stop recording |
| Play | Play back last clip |
| Slot select | Choose SD/SSD slot |
| Format slot | Format media |
| Set clip name | Tag clip with service date |

## Likely Variables

| Variable | Description |
|---|---|
| `transport` | Idle / record / play |
| `slot1_status` / `slot2_status` | Media inserted / mounted / time remaining |
| `current_clip` | Active clip name |
| `timecode` | Current TC |

## TODO

- [ ] Choose hardware (HyperDeck Studio HD Mini vs. ATEM Pro ISO recording)
- [ ] If standalone: assign static IP on Saitama LAN
- [ ] Confirm exact module package name and version
- [ ] Decide naming convention for clips (e.g. `YYYY-MM-DD_service`)
- [ ] Add YAML page or extend the Saitama stream page with record control
- [ ] Document hand-off between OBS (streaming) and recorder (archival)

## Related

- ATEM (likely upstream): [`atem.md`](atem.md)
- OBS (currently doing recording): [`obs-studio.md`](obs-studio.md)
- Saitama location spec: `docs/companion/locations/saitama.md`
