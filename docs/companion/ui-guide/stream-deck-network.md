# Stream Deck Network Modules

## Overview

Stream Deck Network modules connect Stream Decks to Companion over WiFi/ethernet — no USB, no host machine. All three decks connect wirelessly to one Companion server.

```
Stream Deck XL (Network) ──┐
Stream Deck MK2 (Network) ─┤── WiFi/LAN ──→ Companion Server
Stream Deck+ (Network) ────┘
```

## Setup

### 1. Network Connection

Power on the Stream Deck. On first boot (or after reset), it shows a setup screen:
- Connect to WiFi (enter SSID + password via on-screen keyboard)
- Or connect via ethernet if the network module supports it

### 2. Companion Discovery

The Stream Deck searches for Companion via **Bonjour/mDNS** on the local network. If found, it connects automatically.

If Bonjour discovery fails:
- Go to Stream Deck settings (gear icon)
- Select **Manual Configuration**
- Enter Companion server IP and port:
  - **Pi (dev/test):** `192.168.0.175:8000`
  - **Mac Mini (production):** `<mac-mini-ip>:8000`

### 3. Surface Assignment

Once connected, the deck appears in Companion's **Surfaces** tab:
- Each deck gets a unique device ID
- Assign a **startup page** (which page shows on power-on)
- Each deck navigates independently

## Multi-Surface Layout

With three different deck models, assign roles based on hardware strengths:

| Deck | Grid | Best For |
|------|------|----------|
| **XL** (8x4 = 32 buttons) | Most buttons | Primary control — cameras, scenes, full dashboard |
| **Standard MK2** (5x3 = 15 buttons) | Compact | Quick-access — most-used actions, presets, status |
| **Plus** (4x2 buttons + 4 encoders) | Encoders | Audio faders, PTZ control, continuous adjustments |

### Startup Page Assignments

| Deck | Startup Page | Role |
|------|-------------|------|
| XL | Page 1 (Home/Dashboard) | Full production control |
| Standard | Page 10 (Quick Actions) | Scene triggers, presets |
| Plus | Page 20 (Audio/PTZ) | Faders on encoders |

*Page numbers are arbitrary — use whatever makes sense for your layout.*

## Switching Companion Instances

Stream Deck Network modules pair to one server at a time. To switch:

1. On the Stream Deck, go to **Settings** (gear icon or hold a button combo)
2. Navigate to **Server Configuration**
3. Change the server address:
   - Pi: `192.168.0.175` port `8000`
   - Mac Mini: `<mac-mini-ip>` port `8000`
4. Deck reconnects to the new instance (~5 seconds)

**No re-pairing or factory reset needed.** Just change the IP.

### Dev → Production Migration Workflow

```
1. Build & test config on Pi Companion
   └── Stream Decks point to Pi

2. Export config to Git:
   ./apps/companion/scripts/companion-sync.sh --commit

3. Install Companion on Mac Mini
   └── Import config from Git

4. Switch Stream Decks to Mac Mini:
   └── Change server address on each deck

5. Done — same config, new server
```

## Network Requirements

| Port | Protocol | Purpose |
|------|----------|---------|
| 8000 | TCP | Companion web UI + Stream Deck connection |
| 5353 | UDP | Bonjour/mDNS discovery (optional) |
| 16622 | TCP | Satellite protocol (optional, for USB-connected remotes) |

**Firewall:** If the network has client isolation (common on guest WiFi), Stream Decks won't find Companion. Use the same VLAN/subnet for all devices, or configure manual server addresses.

**Bandwidth:** Stream Deck Network uses minimal bandwidth (~50-100 Kbps per deck). Button images are small (72x72 PNG). Works fine on any WiFi.

**Latency:** Button presses are near-instant (<50ms on LAN). Feedback updates may show ~100ms lag on congested WiFi.

## Companion on Mac Mini (Production)

If the Pi doesn't stay at the location, Companion runs natively on macOS:

### Install

```bash
# Download from https://bitfocus.io/companion
# Or via Homebrew (if available):
brew install --cask companion

# Or Docker:
docker run -d --name companion \
    -p 8000:8000 -p 16622:16622 -p 5353:5353/udp \
    -v companion-data:/companion \
    ghcr.io/bitfocus/companion/companion:latest
```

### Import Config

```bash
# Generate from YAML:
python3 apps/companion/scripts/companion-deploy.py generate

# Then import via web UI at http://localhost:8000
# Import/Export tab → Import → select companion.companionconfig
```

### Auto-Start on Boot

macOS: Companion app has "Launch at login" in its settings.
Docker: `docker update --restart unless-stopped companion`

## Troubleshooting

- **Deck doesn't find Companion** — check same subnet, try manual IP entry, verify port 8000 is open
- **Deck connects then disconnects** — check Companion logs for surface errors, verify Companion version matches deck firmware
- **Buttons are blank** — deck connected but no pages assigned; go to Surfaces tab and set startup page
- **Lag on button press** — WiFi congestion; use 5GHz band, reduce network traffic, or use ethernet
- **All decks show same page** — each deck navigates independently unless you've linked them; check Surfaces tab for per-device page assignment
- **Deck won't switch servers** — power cycle the deck, then re-enter server address
- **Bonjour not working** — some routers block mDNS; use manual IP configuration instead
