# Guide: Site Handoff (Vanilla Mode)

How to bring up a fresh production Pi at YIBC or Saitama running
vanilla Companion (no K3s, no Karmada, no GitOps). The repo provides
the seed config; everything else is operator-owned thereafter.

For the alternative (full kube-world stack at the site), see
[ENVIRONMENT-STRATEGY.md §2](../ENVIRONMENT-STRATEGY.md). For now,
vanilla is the production path until the user moves to Japan and
self-services.

---

## What the site gets

| Item | Source |
|---|---|
| Pi 5 with Raspberry Pi OS 64-bit | New hardware |
| Companion 4.2.x running as systemd service | `deploy/vanilla/install.sh` |
| Site-specific env file at `/etc/default/companion` | Copied from `deploy/vanilla/site/<site>/.env.example`, edited with real credentials |
| Seed config import (one-time) | Generated via `seed-export.py`, imported via Companion web UI |
| Tailscale (optional) | Installer adds it; you `sudo tailscale up` once |
| Stream Decks (USB or network) | Operator pairs via Companion web UI |

What the site does **NOT** get:

- K3s. No cluster overhead, no Flux, no Karmada.
- Auto-import. Operator changes are made in Companion's web UI directly
  and persist in Companion's local SQLite DB.
- GitOps reconciliation. Companion is the source of truth at the site,
  not the repo.

---

## Pre-handoff checklist (do at home before shipping the Pi)

- [ ] Pi 5 with 64-bit Raspberry Pi OS (Lite is fine).
- [ ] Headless setup: SSH enabled, hostname set (`pi-yibc` or `pi-saitama`).
- [ ] Static LAN IP reservation in the church's router (or DHCP-with-
      reservation) — Stream Decks need a stable address to connect.
- [ ] **Tailscale auth key minted** at
      https://login.tailscale.com/admin/settings/keys with these tags
      pre-approved (NO `tag:maintenance`):
      - YIBC Pi: `tag:companion,tag:env-prod,tag:site-yibc`
      - Saitama Pi: `tag:companion,tag:env-prod,tag:site-saitama`
      The auth key is single-use; the Pi consumes it during install.
      If you skip this, the operator can register manually later but
      the default-deny ACL won't apply correctly until tags are added.
- [ ] Latest seed config exported:

      ```bash
      python3 apps/companion/scripts/seed-export.py \
          --site yibc \
          --output /tmp/seed-yibc.companionconfig \
          --rewrite-hosts
      ```

      Same for `--site saitama`. Save the resulting `.companionconfig`
      file — you'll import it after Companion is running.
- [ ] Site env values gathered:
      - ProPresenter password
      - OBS WebSocket password
      - Spotify Client ID + Client Secret (from the church's Spotify
        developer-app dashboard, or yours if they're using your account)
      - Pro7 closing graphic macro UUID (if known; can extract later)
      - Spotify playlist URI for service close
- [ ] Yamaha mixer scene Bank A pre-populated (recommend doing this
      before handoff so engineers don't need to set up scenes from
      scratch — see live-test-runbook §2).
- [ ] Backup of the mixer's current state: TF Editor → File → Backup.
      Stash this somewhere safe (1Password, encrypted external drive).

---

## Install procedure (run on the Pi)

### 1. SSH into the Pi

```bash
ssh admin@<pi-lan-ip>
```

### 2. Run the installer

One-liner from a fresh Pi (substitute the Tailscale auth key you minted
in the pre-handoff step):

```bash
curl -fsSL https://raw.githubusercontent.com/jasondashaer/kube-world/main/deploy/vanilla/install.sh \
  | sudo bash -s -- --site yibc \
                    --tailscale-auth-key tskey-auth-XXXXXXXX
```

(Or `--site saitama` for Saitama.)

This:
- Installs deps (curl, libusb, avahi-daemon).
- Creates `companion` user with `plugdev`/`dialout` groups for Stream
  Deck access.
- Downloads Companion 4.2.x release tarball, installs to `/opt/companion`.
- Installs udev rule for Stream Deck access without root.
- Copies `deploy/vanilla/site/<site>/.env.example` to
  `/etc/default/companion`.
- Installs systemd unit at `/etc/systemd/system/companion.service`.
- Enables + starts the service.
- Optionally installs Tailscale (skip with `--no-tailscale`).

Output ends with the Pi's web UI URL (e.g. `http://192.168.1.40:8000`).

### 3. Edit the env file

```bash
sudo $EDITOR /etc/default/companion
```

Fill in real values for each empty placeholder. Don't commit this file
anywhere — it stays on the Pi only.

```bash
sudo systemctl restart companion
sudo journalctl -u companion -f      # watch startup
```

### 4. Open the web UI

Browse to `http://<pi-ip>:8000`. Initial state: empty Companion
install with no buttons, no connections.

### 5. Import the seed

Web UI → **Settings → Import / Export → Import Configuration**. Choose
the `seed-<site>.companionconfig` file you exported earlier.

Companion imports:
- All connections (with hosts already correct, credentials populated
  from env vars at seed-export time).
- All pages for the site (e.g. for YIBC: 20, 21, 22, 30, 31).
- All triggers (ARM-gated chains all DISABLED — operator enables
  per-trigger after walkthroughs).
- All custom variables.

### 6. Pair the Stream Decks

Web UI → **Surfaces** tab.

For Stream Deck Network surfaces (Plus, MK2, XL via Stream Deck app):
- Add Outbound surface, enter the Stream Deck's IP, port 5343.
- Stream Deck's display switches from Companion's setup screen to
  the configured page.

For USB-connected Stream Decks: appear automatically when plugged in.

### 7. Verify connections turn green

Web UI → **Connections**. Each should turn green within 30 seconds:

| Connection | YIBC turns green | Saitama turns green |
|---|---|---|
| ProPresenter | Yes | Yes (its own ProP) |
| Yamaha (TF5/TF1) | Yes (when mixer is on) | Same |
| OBS | Yes (when OBS WS is running) | Same |
| ATEM | (not at YIBC yet) | Yes |
| Spotify | After OAuth — see step 8 | Same |
| PTZ camera | Yes (YIBC only) | n/a |

If a connection is red, check `journalctl -u companion -f` for module
errors, or click the connection in the UI for status detail.

### 8. Spotify OAuth (one-time)

Web UI → **Connections** → click the Spotify connection → **Authorize**.
Browser redirects to Spotify login → user grants permission → token
is stored in Companion's DB. After this, `playPlaylist` actions work.

If swapping accounts later: re-click Authorize. No code change.

### 9. Walk Phase 1-2 of the live-test runbook

[live-test-runbook.md](live-test-runbook.md) phases 1 (static button
validation) and 2 (segment-pad mixer scene recall) confirm everything
works without firing any audio-altering automation. Do this before
the operator runs a live service.

---

## What the operator owns from here

After handoff:

- **Web UI is the workflow.** They make button changes, edit
  connection passwords, add new pages — all via the Companion web UI.
  The seed config gave them a starting baseline; from now on, their
  Companion install is the source of truth.
- **Backups are their job.** Schedule (in their head or via cron):
  - Companion: web UI → Settings → Export → save with date
  - Mixer: TF Editor → File → Backup → save with date
- **Updates: optional.** The Pi can run forever on Companion 4.2.x.
  When they want to upgrade (e.g. Companion 4.3 release), they can
  re-run the installer with `--version 4.3.0` — it preserves data
  while replacing the binary.
- **Stream Deck failures: replace with same model + same IP.** Companion
  recognizes the new device by surface ID (which it remembers).
- **Mixer scenes: edit on the mixer.** Bank A is engineer-owned. The
  segment-transition pads call Recall by number; mixer owns content.

---

## What you (Jackson) own from here

- **Repo continues forward.** New features developed against your home
  dev Pi. Nothing pushed to main affects production sites.
- **Periodic check-in.** Quarterly: ask operators to email you a
  Companion export. You import to YAML via
  `python3 companion-deploy.py export --url ...` (run against a local
  Companion fed the export), diff against repo, capture lessons.
- **On-demand updates.** If they want a new feature, you build it in
  the repo, generate a fresh seed for their site, send to them, they
  re-import. Their drift gets reset to your latest.
- **Maintenance-gated remote access.** Default state: nothing on your
  Tailscale tailnet can reach the production Pi. When the operator
  requests help: open the maintenance window via Tailscale admin web
  UI (add `tag:maintenance` to the Pi), do the work, close the window.
  See [maintenance-access.md](maintenance-access.md).
- **Stream Deck mirror from home.** During a maintenance window, your
  home Mac running Companion Satellite (see
  [`deploy/satellite/install.sh`](../../../deploy/satellite/install.sh))
  can plug a Stream Deck into your Mac and mirror the production
  Companion's pages. Lets you debug button behavior without flying to
  the church. Latency ~150-300ms US ↔ Japan — fine for diagnosis,
  not for live tight ops.

---

## When to flip a site to k3s mode

Trigger: you want GitOps-driven config updates instead of seed-import
roundtrips, OR you're adding observability across multiple sites, OR
operating both vanilla sites manually has become a maintenance tax.

The cutover is in-place on the same Pi — no hardware change, ~3-5 min
downtime, Stream Decks reconnect automatically because they use the
Network module. Full procedure with rollback:
[guides/k3s-cutover.md](k3s-cutover.md). One-liner:

```bash
sudo /opt/kube-world/deploy/k3s-cutover/cutover.sh --site yibc
```

(Run during a maintenance window via SSH over Tailscale.)

For the architectural design see
[../PRODUCTION-CLUSTER.md](../PRODUCTION-CLUSTER.md).

---

## Operator quick-reference card

Print this and tape it next to the Pi.

```
─── COMPANION QUICK REFERENCE ─────────────────────────────────────

Web UI       : http://<pi-ip>:8000
Restart      : sudo systemctl restart companion
Logs         : sudo journalctl -u companion -f
Stop         : sudo systemctl stop companion

Backup config: Web UI → Settings → Export
Restore      : Web UI → Settings → Import

Stream Deck reset: Unplug 5 sec, plug back in
                   (or in Surfaces tab → restart surface)

Connection won't turn green:
  - Check the device IP is correct
  - Check the device is on the same LAN
  - Check the password hasn't been rotated
  - Click "Disable" then "Enable" on the connection

Mixer scene unexpected:
  - Recall a known-good scene from the mixer front panel
  - Recall Bank B scene of same number for pristine baseline
  - Last resort: power-cycle mixer to load saved state

Help: Jackson, jax3200@gmail.com (Tokyo time, expect 24h response)
─────────────────────────────────────────────────────────────────
```

---

## Cross-references

- Vanilla install script: `deploy/vanilla/install.sh`
- Seed export: `apps/companion/scripts/seed-export.py`
- Per-site env templates: `deploy/vanilla/site/<site>/.env.example`
- Live test runbook: [live-test-runbook.md](live-test-runbook.md)
- Secrets handling: [secrets-and-credentials.md](secrets-and-credentials.md)
- Environment strategy: [../ENVIRONMENT-STRATEGY.md](../ENVIRONMENT-STRATEGY.md)
