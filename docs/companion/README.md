# Bitfocus Companion Configuration Guide

Guide for configuring Bitfocus Companion with Stream Deck for production control. Companion runs at `companion.edge1.kubew.dev` on the kube-world edge cluster.

## Documentation Structure

### `integrations/`
One `.md` file per Companion module/integration. Each covers: what the module does, connection setup, available actions/feedbacks, common button patterns, and troubleshooting.

### `ui-guide/`
How Companion itself works — its UI sections, how buttons are built, action/feedback/trigger systems, page management, variable system, and the YAML-to-config workflow.

### `layouts/`
Button layout design and logic — page organization, navigation patterns, color coding, functional groupings, and role-based design philosophy.

## Source Material
Based on the `churchSupport` repo (`/Users/jacksonharris/repos/churchSupport/`) which has:
- YAML-based page configurations (`config/pages/`)
- Connection definitions (`config/connections.yaml`)
- Trigger/variable definitions (`config/triggers.yaml`, `config/variables.yaml`)
- Converter script (`scripts/yaml-to-companion.py`)
- Operator guides and troubleshooting docs

## Quick Start
1. Open `https://companion.edge1.kubew.dev` (allow 15-20s for JS bundle on slow connections)
2. Connect Stream Deck XL via USB to the edge Pi
3. Configure connections under the Connections tab
4. Import or build button pages
5. Test with real equipment

## Stream Deck XL Grid Reference
8 columns x 4 rows = 32 buttons per page. Zero-indexed:
```
Row 0: [0,0] [0,1] [0,2] [0,3] [0,4] [0,5] [0,6] [0,7]
Row 1: [1,0] [1,1] [1,2] [1,3] [1,4] [1,5] [1,6] [1,7]
Row 2: [2,0] [2,1] [2,2] [2,3] [2,4] [2,5] [2,6] [2,7]
Row 3: [3,0] [3,1] [3,2] [3,3] [3,4] [3,5] [3,6] [3,7]
```
