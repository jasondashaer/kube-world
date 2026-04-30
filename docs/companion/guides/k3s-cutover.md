# Guide: K3s Cutover (Vanilla → Full Stack, In-Place)

Convert a vanilla-Companion production Pi (already at YIBC or Saitama,
running for some time) into a full kube-world stack member running
Companion in-pod with the auto-import GitOps pipeline.

Done in-place on the existing Pi. Total downtime ~3-5 minutes. Stream
Decks reconnect transparently (they're on the LAN to the Pi's same IP).

For the design rationale see
[ENVIRONMENT-STRATEGY.md](../ENVIRONMENT-STRATEGY.md) and
[PRODUCTION-CLUSTER.md](../PRODUCTION-CLUSTER.md).

For the access mechanism (you SSH in via Tailscale during a maintenance
window) see [maintenance-access.md](maintenance-access.md).

---

## Pre-conditions

- [ ] Pi has vanilla Companion installed and operating
      (`deploy/vanilla/install.sh` ran successfully).
- [ ] **Stream Decks are using the Network module** (not USB).
      Network-mode Stream Decks reconnect automatically. USB-connected
      Stream Decks would need manual re-pair in the new Companion's
      Surfaces tab — possible but adds 10-15 minutes per deck. Aborts
      with a warning if USB Elgato devices detected.
- [ ] Backups in hand:
    - Companion DB exported from web UI (Settings → Export → save).
    - `/etc/default/companion` env file copied off-Pi.
    - Mixer state via TF Editor → File → Backup.
- [ ] `tag:maintenance` is on the Pi in Tailscale (otherwise SSH won't
      land — see [maintenance-access.md](maintenance-access.md)).
- [ ] You're physically near a person at the church OR you've
      coordinated a quiet window. Stream Decks WILL be unresponsive for
      ~3 minutes during the cutover.
- [ ] Tested the cutover on a staging Pi at home if possible.

---

## Procedure

### 1. Open the maintenance window

Tailscale admin web UI → add `tag:maintenance` to the production Pi.
Wait 30 seconds for ACL propagation.

### 2. SSH in

```bash
ssh admin@pi-yibc.<tailnet>.ts.net
```

### 3. Run the cutover

Standalone single-cluster mode (recommended for first cutover —
simplest topology, no Karmada dependency):

```bash
sudo /opt/kube-world/deploy/k3s-cutover/cutover.sh --site yibc
```

Or if you've already brought up a separate Karmada control plane and
want this Pi to register as an edge cluster:

```bash
sudo /opt/kube-world/deploy/k3s-cutover/cutover.sh \
    --site yibc \
    --join <karmada-token> <karmada-control-host>
```

Watch the output. The script:

| Step | Approx duration | Visible effect |
|---|---|---|
| Snapshot data + env + systemd unit → `/var/lib/companion.pre-k3s/` | <10s | Disk write |
| Stop systemd `companion.service` | instant | **Stream Decks lose connection** |
| Install K3s (download + install) | 90-120s | Network + Pi CPU spike |
| Wait for K3s node Ready | <10s | — |
| Clone kube-world repo | 5-10s | — |
| Apply Companion manifests via kubectl | 5s | Deployment scheduled |
| Pod pulls Companion image (~600MB on first pull) | 30-90s on Pi | Network |
| Init container (`companion-deploy.py`) imports config | 10-30s | — |
| Companion main container starts | 10s | Web UI begins responding |
| Verify HTTP 200 on `:8000` | <10s | — |
| Disable + remove old systemd unit | <5s | Cleanup |
| **Stream Decks reconnect** to same Pi LAN IP | <10s after web UI up | Pages reappear |

Total ~3-5 minutes from "stop service" to "Stream Decks back."

### 4. Verify

From your Mac (via Tailscale during maintenance window):

```bash
# Cluster health
ssh admin@pi-yibc.<tailnet>.ts.net "k3s kubectl get pods -n companion"
# Expected: companion-XXX Running, companion-deploy-XXX Running.

# Companion UI
open http://pi-yibc.<tailnet>.ts.net:8000

# Recent deploy logs
ssh admin@pi-yibc.<tailnet>.ts.net "k3s kubectl logs -n companion \
    deploy/companion-deploy -c deploy --tail=50"
# Should show "Import successful" with connection / button counts.
```

Walk Phase 1 of [live-test-runbook.md](live-test-runbook.md) — static
button validation. Press a few buttons. If they fire actions on the
mixer / OBS / ProPresenter, the cutover succeeded.

### 5. Close the maintenance window

Tailscale admin web UI → remove `tag:maintenance` from the Pi. Default-
deny rules re-engage within 30s.

### 6. Document the change

- Update `apps/companion/CLAUDE.md` site-mode listing (TBD field).
- Update `docs/companion/STATUS.md` — this site is now k3s mode.
- Commit + push.

---

## What changes for the operator after cutover

| Before (vanilla) | After (k3s) |
|---|---|
| Web UI changes persist in Companion's local DB | Web UI changes are reverted by Karmada within ~1 min |
| Backups via web UI Export | Backups via Velero (cluster-side, automatic) + git history |
| Pi reboot brings Companion back via systemd | Pi reboot brings K3s up, K3s starts Companion pod |
| Software updates: re-run install.sh with new --version | Software updates: bump image tag in deployment.yaml + commit |
| Stream Deck pairings stored in local DB | Stream Deck pairings stored in PVC; survive Pod restarts |

The operator interface (web UI, Stream Deck buttons) is identical. They
will not notice the underlying change.

The ONE thing they'll experience differently: any change they make via
the web UI now gets reverted by GitOps. Tell them: "for permanent
changes, send Jackson a request — I'll commit it to the repo."

---

## Failure modes + recovery

### Symptom: K3s install fails

```bash
sudo /opt/kube-world/deploy/k3s-cutover/cutover.sh --rollback
```

Restores systemd Companion + DB snapshot. Stream Decks reconnect to
vanilla Companion within ~30s.

### Symptom: K3s installs but Companion pod stays Pending

```bash
k3s kubectl describe pod -n companion -l app.kubernetes.io/name=companion
```

Look for events. Common causes:
- **PVC unbound**: storage class missing. Check `k3s kubectl get sc`.
  Default should be `local-path`.
- **Image pull failure**: Pi can't reach ghcr.io. Check Tailscale +
  internet connectivity.
- **Resource limits**: Pi has insufficient RAM/CPU. Adjust limits in
  `apps/companion/overlays/<env>/`.

If unrecoverable: `sudo cutover.sh --rollback`.

### Symptom: Pod runs but Stream Decks don't reconnect

The Stream Deck Network module connects to the Pi's LAN IP on TCP/5343.
After cutover the Pi's IP didn't change; the new Companion service is
on `hostNetwork: true` → it owns port 5343 same as before.

Diagnose:

```bash
# Confirm the new Companion is listening on :5343
ssh admin@pi-yibc.<tailnet>.ts.net "ss -tlnp | grep 5343"

# Confirm Stream Deck side: from a laptop on the LAN
nc -zv 192.168.1.40 5343    # Pi's LAN IP

# In the new Companion UI, check Surfaces tab — known surface IDs
# should appear (the import preserves them via "surfaces: known: unchanged"
# in companion-deploy.py's importFull config).
```

If still disconnected: power-cycle the Stream Decks (unplug 5s, plug
back in). They retry outbound and re-establish.

### Symptom: OAuth tokens lost

OAuth refresh tokens (Spotify) live in Companion's SQLite DB. The
cutover copies the DB to the PVC, so tokens should persist. If for
some reason they don't (e.g. PVC didn't bind, fresh DB started):

- Open Companion web UI → Connections → Spotify → Authorize.
- One-time re-auth. Token persists in the new PVC for future cutovers
  / reboots.

### Full disaster: rollback to vanilla

```bash
sudo /opt/kube-world/deploy/k3s-cutover/cutover.sh --rollback
```

This:
1. Stops + removes the K3s Companion deployment.
2. Uninstalls K3s (`/usr/local/bin/k3s-uninstall.sh`).
3. Restores `/var/lib/companion`, `/etc/default/companion`, the
   systemd unit from `/var/lib/companion.pre-k3s/`.
4. Re-enables + starts vanilla `companion.service`.

Total time: ~2 minutes.

After rollback: investigate what failed, fix, run cutover again.

---

## When to do this

This is a **deliberate, planned migration**, not an emergency procedure.
Triggers:

- You've moved closer to the sites (e.g. now in Japan) and can
  self-service.
- You want GitOps-driven config updates instead of manual seed
  re-imports.
- You want centralized observability (Prometheus / Grafana) across
  multiple sites.
- You're adding a third site and the per-site complexity is becoming
  hard to manage manually.

NOT triggers:

- "I want to try K3s" — overkill if vanilla works.
- "The operators want a fancier UI" — same Companion, same UI.
- "GitLab pipeline is broken" — fix the pipeline, not the deploy mode.

If unsure: stay vanilla. The handoff value of "operator-owned, simple,
recoverable from a phone call" is real.

---

## Cross-references

- Cutover script: [`deploy/k3s-cutover/cutover.sh`](../../../deploy/k3s-cutover/cutover.sh)
- Maintenance access: [maintenance-access.md](maintenance-access.md)
- Production cluster design: [../PRODUCTION-CLUSTER.md](../PRODUCTION-CLUSTER.md)
- Vanilla install (state before cutover): [`deploy/vanilla/install.sh`](../../../deploy/vanilla/install.sh)
- Site handoff (operator-facing): [site-handoff.md](site-handoff.md)
- Live-test runbook (post-cutover validation): [live-test-runbook.md](live-test-runbook.md)
