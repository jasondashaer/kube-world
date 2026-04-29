# Companion Locations

Companion runs on `pi-edge-1` and is physically transported between locations. The same `companion-deploy.py` import pipeline serves both locations — connections for both are always defined; only the local-network ones connect successfully.

## Location index

| Location | Status | Subnet(s) | Stream Decks | Page range | Doc |
|---|---|---|---|---|---|
| YIBC | Active (production) | `192.168.1.0/24` | Stream Deck+ (page 20-21), Stream Deck MK2 (page 30) | 20-29, 30-39 | [yibc.md](yibc.md) |
| Saitama | Testing | `192.168.10.0/24`, `192.168.68.0/24`, `192.168.1.0/24` (chained) | Stream Deck XL (page 40-43) | 40-49 | [saitama.md](saitama.md) |

## Page numbering convention

Pages are blocked into ranges by device + location so a single import never collides:

| Range | Device | Location |
|---|---|---|
| 20–29 | Stream Deck+ | YIBC |
| 30–39 | Stream Deck MK2 | YIBC |
| 40–49 | Stream Deck XL | Saitama |

## Connection isolation

Two parallel connection sets keep both locations active in config. Whichever location the Pi is at, the unused location's connections show disconnected — this is expected and acceptable. See `apps/companion/config/connections.yaml`.

| Connection | Location | Used by |
|---|---|---|
| `yamaha_yibc` | YIBC | Plus, MK2 |
| `yamaha_saitama` | Saitama | XL |
| `propresenter_yibc` | YIBC | Plus, MK2 |
| `propresenter_saitama` | Saitama | XL |
| `ptz` | YIBC | Plus |
| `homeassistant` | YIBC | (future) |

## Network reality

Pi-edge-1 runs Companion with `hostNetwork: true` and uses DHCP on whatever LAN it joins. When the Pi changes networks:

- All surface IPs (Stream Decks, mixer, ProPresenter, PTZ) likely change.
- Update via GitOps commit (`apps/companion/config/`), not Companion UI.
- K3s embedded etcd may bind to old IP — symptom is Companion UI 404. Fix: power cycle Pi or `systemctl restart k3s`.

## Cross-references

- Devices: [`docs/companion/devices/`](../devices/)
- Pipeline: [`docs/companion/PIPELINE.md`](../PIPELINE.md)
- Connections (source): [`apps/companion/config/connections.yaml`](../../../apps/companion/config/connections.yaml)
- Surfaces (source): [`apps/companion/config/surfaces.yaml`](../../../apps/companion/config/surfaces.yaml)
