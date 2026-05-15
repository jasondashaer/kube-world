# YIBC MK2 Archive

Files here are kept for resurrection but **not** referenced by any
kustomization. They will not be imported into Companion until added
back to `apps/companion/kustomization.yaml` and
`apps/companion/gitops/kustomization.yaml`.

## Contents

- `mk2-page01-ops-yamaha.yaml` — original page 30 with Yamaha TF5 mute /
  duck / pre-service / close-service automation. Holds smooth-fade
  workaround sequences and the full close-service chain.
- `mk2-page02-segments-yamaha.yaml` — segment-transition pad (page 31)
  driving Yamaha scene recalls for service flow segments.

## Why archived

Yamaha TF5 control retired from MK2 surface (2026-05-04). The mixer
itself is still present and Companion's `yamaha_yibc` connection
stays connected — just no buttons currently route to it. To bring
back, copy the relevant button blocks into the active page YAML and
re-add the file to both kustomizations.
