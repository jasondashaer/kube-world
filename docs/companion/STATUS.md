# Companion Status — Living Document

> **This is a LIVING DOCUMENT.** Update whenever the Pi relocates, surfaces are reseated, or connection status changes materially. Do not delete history — append a new dated section if substantive shifts occur.

Last update: **2026-04-29** (initial seed; values reflect intent, not verified live state)

See also: [ARCHITECTURE.md](ARCHITECTURE.md), [PIPELINE.md](PIPELINE.md), [INVENTORY.md](INVENTORY.md), [CHANGELOG.md](CHANGELOG.md).

## 1. Pi Location

| Field | Value |
|-------|-------|
| **Current site** | TBD (YIBC vs Saitama) |
| **Pi hostname** | `pi-edge-1` |
| **Current LAN IP** | TBD (192.168.1.x at YIBC, 192.168.10.x at Saitama) |
| **Tailscale IP** | stable: `pi-edge-1.tailab53c1.ts.net` |
| **K3s status** | TBD (`systemctl status k3s` on the Pi) |
| **Companion pod status** | TBD (`kubectl get pod -n companion`) |
| **Last GitOps reconcile** | TBD |

## 2. Surfaces Connected

Source of truth: `apps/companion/config/surfaces.yaml`. Live registration state is in Companion's web UI under Surfaces. Decks self-register on first connect to TCP 16622.

| Group ID | Name | Expected IP | Site | Startup Page | Live? |
|----------|------|-------------|------|--------------|-------|
| `streamdeck:A00NA53835A5F1` | Stream Deck XL | `192.168.1.41` (last set; will change at Saitama) | Saitama | 40 | TBD |
| `streamdeck:A00WA5241MWHZB` | Stream Deck+ | `192.168.1.42` | YIBC | 20 | TBD |
| `streamdeck:A00SA5432NCLFZ` | Stream Deck MK2 | `192.168.1.43` | YIBC | 30 | TBD |

## 3. Connection Statuses

By design, the connections matching the **other** location will always show disconnected. See [ARCHITECTURE.md §4](ARCHITECTURE.md#4-connection-model-parallel-per-location-pattern).

| Connection ID | Module | Target | Expected Status (when at YIBC) | Expected Status (when at Saitama) | Live |
|---------------|--------|--------|--------------------------------|-----------------------------------|------|
| `homeassistant` | `homeassistant-server` | cluster DNS | OK | OK | TBD |
| `ptz` | `ptzoptics-visca` | 192.168.1.113 | OK | DISCONNECTED | TBD |
| `yamaha_yibc` | `yamaha-rcp` | 192.168.1.54 | OK | DISCONNECTED | TBD |
| `propresenter_yibc` | `renewedvision-propresenter` | 192.168.1.2:1025 | OK | DISCONNECTED | TBD |
| `yamaha_saitama` | `yamaha-rcp` | 192.168.10.30 | DISCONNECTED | OK | TBD |
| `propresenter_saitama` | `renewedvision-propresenter` | 192.168.68.55:53678 | DISCONNECTED | OK | TBD |

## 4. Last Successful Import

| Field | Value |
|-------|-------|
| **Git commit hash** | TBD |
| **Date/time** | TBD |
| **Job name** | TBD (`companion-deploy-<checksum>`) |
| **Pages imported** | TBD |
| **Connections imported** | TBD |
| **Triggers imported** | TBD (most disabled by default) |

## 5. Known Issues / Outstanding Items

| Item | Status | Notes |
|------|--------|-------|
| Third YIBC Stream Deck not in surfaces.yaml | Open | Confirm serial and add startup page entry |
| OBS connection not defined | Open | Triggers reference `obs:*` actions but no OBS connection in `connections.yaml` |
| Saitama Yamaha TF1 channel map | Incomplete | Confirm channels from physical console |
| ProPresenter `presentation_name` value for "Closing" trigger | Unverified | Triggers disabled until validated against live PP variable list |
| Service-flow triggers all disabled | Intentional | Per `triggers.yaml` header: enable only after live testing |

## 6. Update Procedure

When updating this file:

1. Edit the section that changed. Don't blank out unrelated sections.
2. Bump the "Last update" date at the top.
3. Append a one-line entry to [CHANGELOG.md](CHANGELOG.md) summarizing the change.
4. Commit with message `docs: companion status — <what changed>`.
5. Push. (No GitOps reconcile triggered — docs aren't deployed.)

## 7. Quick Health Check Commands

```bash
# From dev workstation:
flux get all -A | grep companion
kubectl --context karmada-apiserver get configmap -n companion

# On pi-edge-1:
kubectl get pod,job,configmap -n companion
kubectl logs -n companion deployment/companion --tail=100
kubectl logs -n companion -l job-name -c companion-deploy --tail=200

# Companion HTTP health:
curl -sI https://companion.edge1.kubew.dev/ | head -1
# expect: HTTP/2 200
```
