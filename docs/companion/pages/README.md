# Companion Page Registry

Companion uses a flat global page-number namespace (1-99). Pages are partitioned by location and device so that any Stream Deck can land on a page that fits its grid. Plus encoders use page navigation to flip between paired pages (20 ↔ 21).

## Numbering convention

| Range | Reserved for |
|-------|--------------|
| 1-19  | Reserved (default `Page 1` from Companion is unused) |
| 20-29 | YIBC — Stream Deck+ (4×4 with encoders) |
| 30-39 | YIBC — Stream Deck MK2 (5×3) |
| 40-49 | Saitama — Stream Deck XL (8×4) |
| 50-59 | Reserved — future Saitama secondary surface |
| 60-79 | Reserved — additional locations |
| 80-99 | Reserved — global utility pages (e.g. SCRATCH, LOCK) |

## Active pages

| Page | Name | Location | Device | Grid | Source YAML | Doc |
|------|------|----------|--------|------|-------------|-----|
| 20 | PTZ Encoder Control | YIBC | Plus | 4×4 | `apps/companion/config/pages/yibc/plus-page01-ptz.yaml` | [yibc-plus-20-ptz.md](yibc-plus-20-ptz.md) |
| 21 | PTZ D-Pad | YIBC | Plus | 4×4 | `apps/companion/config/pages/yibc/plus-page02-dpad.yaml` | [yibc-plus-21-dpad.md](yibc-plus-21-dpad.md) |
| 30 | Ops | YIBC | MK2 | 5×3 | `apps/companion/config/pages/yibc/mk2-page01-ops.yaml` | [yibc-mk2-30-ops.md](yibc-mk2-30-ops.md) |
| 31 | Segments | YIBC | MK2 | 5×3 | `apps/companion/config/pages/yibc/mk2-page02-segments.yaml` | [yibc-mk2-31-segments.md](yibc-mk2-31-segments.md) |
| 40 | Home Dashboard | Saitama | XL | 8×4 | `apps/companion/config/pages/saitama/xl-page01-home.yaml` | [saitama-xl-40-home.md](saitama-xl-40-home.md) |
| 41 | Audio Mixer | Saitama | XL | 8×4 | `apps/companion/config/pages/saitama/xl-page02-audio.yaml` | [saitama-xl-41-audio.md](saitama-xl-41-audio.md) |
| 42 | ProP | Saitama | XL | 8×4 | `apps/companion/config/pages/saitama/xl-page03-slides.yaml` | [saitama-xl-42-prop.md](saitama-xl-42-prop.md) |
| 43 | Stream | Saitama | XL | 8×4 | `apps/companion/config/pages/saitama/xl-page04-stream.yaml` | [saitama-xl-43-stream.md](saitama-xl-43-stream.md) |
| 44 | Segments | Saitama | XL | 8×4 | `apps/companion/config/pages/saitama/xl-page05-segments.yaml` | [saitama-xl-44-segments.md](saitama-xl-44-segments.md) |

## Plus page rotation (20 ↔ 21)

The Stream Deck+ at YIBC pairs pages 20 and 21. Encoder **E3 (PAGE)** rotates between them:

- **On page 20** (`PTZ Encoder Control`): rotate either direction → page 21. Press → page 20 (home).
- **On page 21** (`PTZ D-Pad`): rotate either direction → page 20. Press → page 20.

LCD strip column 3 also has a "PAGE ►" pressable label that performs the same flip. This makes the Plus a self-contained two-page mode-switching surface — no need to leave for a parent menu.

## Cross-references

- [Architecture](../ARCHITECTURE.md) — pipeline overview
- [Action IDs reference](../reference/action-ids.md)
- [Variables reference](../reference/variables.md)
- [Setup guide](../guides/setup-from-scratch.md)
