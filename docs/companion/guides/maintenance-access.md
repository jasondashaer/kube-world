# Guide: Maintenance Access (Default-Deny Model)

Production Companion Pis are reachable on Tailscale (registered, can
phone home) but **no inbound ports are open from any other tailnet
device** unless `tag:maintenance` is explicitly added to the destination
Pi via the Tailscale admin console.

This is the security posture: nothing affects production unless
explicitly enabled, and every flip is logged.

For the underlying ACL design + tag taxonomy see
[infrastructure/tailscale-acl.json](../../../infrastructure/tailscale-acl.json).

---

## What "default-deny" means in practice

When the Pi is in its locked state (no `tag:maintenance`):

| Tried from | To Pi (locked) on | Result |
|---|---|---|
| Your laptop (tag:admin) | TCP/22 (SSH) | DENIED — can't shell in |
| Your laptop (tag:admin) | TCP/8000 (Companion UI) | DENIED — UI unreachable |
| Your laptop (tag:admin) | TCP/6443 (K3s API) | DENIED — kubectl can't reach |
| Your home Mac (tag:satellite) | TCP/16622 (Companion brain) | DENIED — Stream Deck mirror won't connect |
| Onsite helper laptop (tag:onsite-helper) | TCP/8000 | DENIED |
| Stream Decks on the LAN | TCP/5343 (network module) | OK — LAN-local, not Tailscale |
| The Pi itself outbound to LAN | any | OK — egress to local AV systems |
| The Pi itself outbound to Tailscale control plane | any | OK — required to stay registered |

Companion keeps running. Stream Decks keep working. Engineers operate
their service. You can't see in or push changes.

When you add `tag:maintenance` to the Pi:

| From | To | Now |
|---|---|---|
| tag:admin | TCP/22, 80, 443, 8000, 6443, 16622 | OK |
| tag:satellite | TCP/16622 | OK |
| tag:onsite-helper | TCP/8000 only | OK |

When you remove `tag:maintenance`, doors close again within ~30 seconds
of the ACL update propagating.

---

## Procedure: Open a maintenance window

### Via Tailscale admin web UI (canonical)

1. Open https://login.tailscale.com/admin/machines.
2. Find the production Pi (e.g. `pi-yibc.<tailnet>.ts.net`).
3. Click the `...` menu → **Edit machine settings**.
4. Under **Tags**, add `tag:maintenance`. Save.
5. Verify within 30 seconds: from your laptop,
   `ssh admin@pi-yibc.<tailnet>.ts.net "echo ok"` should succeed.
6. Do the work.
7. Return to the same screen. Remove `tag:maintenance`. Save.
8. Verify lockout: same SSH should hang/fail.

The audit trail lives in
https://login.tailscale.com/admin/logs/configuration — every tag
change is recorded with timestamp + admin identity.

### Via Tailscale CLI (alternative, requires admin oauth token)

```bash
# Open
tailscale set --device pi-yibc --advertise-tags=tag:companion,tag:env-prod,tag:site-yibc,tag:maintenance

# Close
tailscale set --device pi-yibc --advertise-tags=tag:companion,tag:env-prod,tag:site-yibc
```

This is a remote operation against the Tailscale API; it does NOT
require SSH into the Pi. Each call is logged.

---

## What you can do during a maintenance window

| Need | Tool | Port |
|---|---|---|
| SSH into the Pi | `ssh admin@pi-<site>.<tailnet>.ts.net` | 22 |
| Companion web UI | browser → `http://pi-<site>.<tailnet>.ts.net:8000` | 8000 |
| Mirror their Stream Deck on yours | run Companion Satellite on your Mac, target `pi-<site>:16622` | 16622 |
| `kubectl` (post-K3s-cutover) | `kubectl --kubeconfig=...` | 6443 |
| Edit `/etc/default/companion` (vanilla) | SSH + `sudo $EDITOR` + restart service | 22 |
| Re-import a fresh seed | SSH + `sudo systemctl restart companion` to pick up env, OR via Companion UI | 22 + 8000 |
| Inspect K3s pods (post-cutover) | `kubectl get pods -n companion` | 6443 |

---

## Pattern: minimal-time maintenance

Open the window only as long as needed. Close it when done.

Example: operator emails about a button label that's wrong.

1. Open maintenance on the affected site (~30s ACL propagation).
2. Decide on fix path:
    - **Code fix**: edit YAML in repo locally, push to git. K3s mode auto-imports. Vanilla mode requires re-importing a new seed (manual).
    - **Hot fix via Companion UI**: SSH-tunnel or browser to `pi-<site>:8000`, fix in UI. (Note: vanilla site, this drift is fine. K3s site, Karmada will revert if you don't also commit to git.)
    - **Mirror via satellite**: launch satellite on your Mac, debug interactively, decide on fix.
3. Validate: ask operator to test, or test via satellite mirror.
4. Close maintenance.

Typical window: 5-15 minutes. Audit log shows it.

---

## Pattern: emergency / "right now" access

If maintenance via web UI is too slow (Tailscale ACL propagation ~30s,
plus your time to log in):

1. Tailscale admin web UI is accessible from any browser. ~10s to open + click.
2. If Tailscale itself is down (rare), your laptop on the church LAN
   would have to be physically present — same as any cloud-managed system.
3. There is no "break glass" override that bypasses the ACL by design.
   That is the entire point of default-deny.

If you need genuinely faster response: a `tag:onsite-helper` laptop at
the church can be granted `tag:maintenance` reach to port 8000 only —
local engineer can fix UI-level issues immediately without touching
SSH or K3s API. This is already in the ACL; just hand a tagged
laptop to the church's tech lead.

---

## What you CANNOT do, even during maintenance

| Need | Why not |
|---|---|
| Access OS-level secrets via Tailscale-only auth | SSH still requires the user's actual SSH key — Tailscale ACL gates the *network path*, not the auth |
| Bypass Companion's password / OAuth on connections | Tailscale doesn't manage Companion-internal auth. Existing creds still required. |
| Reach the mixer / OBS / ProPresenter from your laptop directly | Those systems are LAN-local at the church, not on Tailscale. You reach them by tunneling through the Pi (e.g. SSH local-forward) |
| Edit ACL itself without admin role | tagOwners restricts who can mutate tags. Only `autogroup:admin` can apply `tag:maintenance`. |

---

## Tunneling LAN-side AV systems through the Pi

Mixer + OBS + ProPresenter live on the church LAN, NOT on Tailscale.
To debug them from your Mac during a maintenance window:

```bash
# SSH with local port-forwards to the AV systems behind the Pi
ssh -L 49280:192.168.1.54:49280 \  # Yamaha TF5 RCP
    -L 4455:192.168.1.50:4455  \   # OBS WS
    -L 1025:192.168.1.2:1025   \   # ProPresenter
    admin@pi-yibc.<tailnet>.ts.net
```

Now `localhost:49280` on your Mac talks to the YIBC mixer through the Pi.
Useful for interactive `mixer-state-deploy.py --host localhost` from
home, OBS WS troubleshooting, etc.

---

## What the operators see / can do

Operators at the church do NOT need Tailscale at all for daily operation:

- Stream Decks → Pi via local LAN. Local network only.
- Mixer, OBS, ProPresenter → Pi via local LAN. Local network only.
- Operator's laptop → Pi via LAN (`http://192.168.1.40:8000`) — local
  Companion UI, no Tailscale required.

They WILL need Tailscale only if they want remote access to monitor
the system from off-site. In that case: hand them a Mac/laptop tagged
`tag:onsite-helper` via Tailscale, registered separately. ACL grants
them only `:8000` to maintenance-tagged Pis at their own site (no SSH,
no K3s, no satellite). Even then: only when maintenance window is open.

For the standard handoff (see [site-handoff.md](site-handoff.md)),
operators don't get a Tailscale account or `tag:onsite-helper`. The Pi
is on Tailscale only so YOU can manage it. They never see Tailscale.

---

## Lifecycle of a Pi's Tailscale tags

1. **First registration** (during install.sh): Pi gets base tags from
   the auth key:
   - `tag:companion`, `tag:env-prod`, `tag:site-yibc` (or `site-saitama`).
   - The auth key is minted via the Tailscale admin console with
     these tags pre-approved (`autoApprovers` gate not used — admin
     approves at mint time).

2. **Operating state**: Pi has its base tags. Default-deny ACL applies.
   Pi is reachable on Tailscale (control plane only) but not on TCP
   ports from other tailnet members.

3. **Maintenance**: admin adds `tag:maintenance` via web UI. Pi has
   four tags now. ACL grants temporary inbound from `tag:admin` /
   `tag:satellite` / `tag:onsite-helper`.

4. **Maintenance close**: admin removes `tag:maintenance`. Pi back to
   three tags. Inbound ports close.

5. **K3s cutover** (future): admin adds `tag:k8s-control` and
   `tag:k8s-worker`. Pi has five tags. K3s nodes can talk to each
   other; default-deny inbound from non-cluster sources still applies.

6. **Decommission**: admin removes the Pi from Tailscale. Pi can no
   longer reach control plane → loses tailnet identity → ACL no longer
   applies. (Pi-on-LAN is unaffected; network operates locally.)

---

## Cross-references

- ACL definition: [infrastructure/tailscale-acl.json](../../../infrastructure/tailscale-acl.json)
- Vanilla install (sets initial tags via auth key): [`deploy/vanilla/install.sh`](../../../deploy/vanilla/install.sh)
- Site handoff: [site-handoff.md](site-handoff.md)
- K3s cutover (will use `tag:maintenance` for the install window): [k3s-cutover.md](k3s-cutover.md)
- Satellite setup (your home Mac): [`deploy/satellite/install.sh`](../../../deploy/satellite/install.sh) (planned)
- Tailscale admin: https://login.tailscale.com/admin/machines
- Tailscale activity log: https://login.tailscale.com/admin/logs/configuration
