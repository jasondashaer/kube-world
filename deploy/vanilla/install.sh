#!/usr/bin/env bash
# Vanilla Companion install for production sites (YIBC, Saitama).
#
# Idempotent: safe to re-run.
#
# Architecture: Companion install itself is delegated to the official
# bitfocus/companion-pi installer. We layer on top:
#   - Per-site env file at /etc/default/companion (loaded by systemd)
#   - systemd drop-in adding EnvironmentFile reference
#   - Tailscale install + register with default-deny tag set
#
# This keeps us aligned with the upstream Pi install path (binary builds
# of Companion are not published for ARM directly — companion-pi clones
# + builds the Node.js source tree at install time, ~10-15 min on a Pi 5).
# Bitfocus controls the Companion install; we layer site-specific config.
#
# Usage (run on the Pi):
#   curl -fsSL https://raw.githubusercontent.com/jasondashaer/kube-world/main/deploy/vanilla/install.sh | sudo bash -s -- --site <site_name>
#
# Or local checkout:
#   sudo ./install.sh --site yibc
#
# Args:
#   --site <name>       Required. yibc | saitama (must match a site dir).
#   --hostname <name>   Tailscale hostname override. Default: pi-<site>.
#   --build <ver>       Companion build (default: stable). See
#                       https://github.com/bitfocus/companion-pi for
#                       valid values (stable | beta | experimental | <commit-hash>).
#   --no-tailscale      Skip Tailscale install.
#   --tailscale-auth-key <KEY>
#                       Pre-mint via Tailscale admin with these base tags:
#                         tag:companion, tag:env-prod, tag:site-<site>
#                       NEVER include tag:maintenance (added later via
#                       admin web UI; security boundary).

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
# Args + defaults
# ─────────────────────────────────────────────────────────────────────

SITE=""
HOSTNAME_OVERRIDE=""
COMPANION_BUILD="stable"
INSTALL_TAILSCALE=1
TAILSCALE_AUTH_KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site) SITE="$2"; shift 2 ;;
        --hostname) HOSTNAME_OVERRIDE="$2"; shift 2 ;;
        --build) COMPANION_BUILD="$2"; shift 2 ;;
        --no-tailscale) INSTALL_TAILSCALE=0; shift ;;
        --tailscale-auth-key) TAILSCALE_AUTH_KEY="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,/^set -euo pipefail/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

TS_HOSTNAME="${HOSTNAME_OVERRIDE:-pi-${SITE}}"

if [[ -z "$SITE" ]]; then
    echo "ERROR: --site is required (e.g. --site yibc)" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root (sudo)" >&2
    exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64) : ;;
    x86_64) : ;;
    *) echo "ERROR: unsupported arch $ARCH (companion-pi requires arm64 or x64)" >&2; exit 1 ;;
esac

log()  { printf '\033[32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n'    "$*"; }
err()  { printf '\033[31m[error]\033[0m %s\n'   "$*" >&2; }

# ─────────────────────────────────────────────────────────────────────
# Resolve repo for site env file
# ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SITE_DIR="$SCRIPT_DIR/site/$SITE"

if [[ ! -d "$SITE_DIR" ]]; then
    log "Site dir not found locally; cloning kube-world to /opt/kube-world..."
    apt-get install -y -qq git
    if [[ -d /opt/kube-world ]]; then
        git -C /opt/kube-world fetch --quiet origin main
        git -C /opt/kube-world reset --hard --quiet origin/main
    else
        git clone --depth=1 https://github.com/jasondashaer/kube-world.git /opt/kube-world
    fi
    SCRIPT_DIR="/opt/kube-world/deploy/vanilla"
    SITE_DIR="$SCRIPT_DIR/site/$SITE"
fi

if [[ ! -d "$SITE_DIR" ]]; then
    err "Site '$SITE' not found at $SITE_DIR"
    err "Available: $(ls "$SCRIPT_DIR/site/" 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# Companion install — delegate to bitfocus/companion-pi
# ─────────────────────────────────────────────────────────────────────

if [[ -d /opt/companion ]] && systemctl is-enabled companion >/dev/null 2>&1; then
    log "Companion already installed at /opt/companion (skipping companion-pi installer)"
    log "  To upgrade: sudo companion-update"
else
    log "Running bitfocus/companion-pi installer (build=$COMPANION_BUILD)..."
    log "  This downloads Node.js + Companion source + builds. ~10-15 min on Pi 5."
    export COMPANION_BUILD="$COMPANION_BUILD"
    curl -fsSL https://raw.githubusercontent.com/bitfocus/companion-pi/main/install.sh \
        | bash
fi

# ─────────────────────────────────────────────────────────────────────
# Site env file (cleartext credentials, mode 640, root:companion)
# ─────────────────────────────────────────────────────────────────────

ENV_FILE="/etc/default/companion"
if [[ ! -f "$ENV_FILE" ]]; then
    log "Installing site env file from $SITE_DIR/.env.example..."
    if [[ -f "$SITE_DIR/.env.example" ]]; then
        cp "$SITE_DIR/.env.example" "$ENV_FILE"
        chmod 640 "$ENV_FILE"
        chown root:companion "$ENV_FILE"
        warn "Edit $ENV_FILE to fill in real credentials before live use:"
        warn "  sudo \$EDITOR $ENV_FILE"
        warn "  sudo systemctl restart companion"
    else
        warn "No .env.example for site $SITE — creating empty $ENV_FILE"
        touch "$ENV_FILE"
        chmod 640 "$ENV_FILE"
        chown root:companion "$ENV_FILE"
    fi
else
    log "Env file $ENV_FILE already exists — leaving alone"
fi

# ─────────────────────────────────────────────────────────────────────
# systemd drop-in: layer EnvironmentFile onto companion-pi's unit
# ─────────────────────────────────────────────────────────────────────

DROPIN_DIR="/etc/systemd/system/companion.service.d"
DROPIN_FILE="$DROPIN_DIR/site-env.conf"

log "Installing systemd drop-in → $DROPIN_FILE"
mkdir -p "$DROPIN_DIR"
cat > "$DROPIN_FILE" <<EOF
# kube-world site-env drop-in for companion-pi's stock unit.
# companion-pi owns /etc/systemd/system/companion.service; we layer
# additional env loading via this drop-in so updates of companion-pi
# don't overwrite our config.
[Service]
EnvironmentFile=-/etc/default/companion
EOF

systemctl daemon-reload
systemctl restart companion 2>&1 | head -5 || true

# ─────────────────────────────────────────────────────────────────────
# Tailscale
# ─────────────────────────────────────────────────────────────────────

if [[ $INSTALL_TAILSCALE -eq 1 ]]; then
    if ! command -v tailscale >/dev/null 2>&1; then
        log "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    else
        log "Tailscale already installed — leaving alone"
    fi

    TAGS="tag:companion,tag:env-prod,tag:site-${SITE}"

    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        # Auth key MUST have these tags pre-authorized at mint time.
        log "Registering Tailscale with tags: $TAGS, hostname: $TS_HOSTNAME"
        tailscale up \
            --auth-key="$TAILSCALE_AUTH_KEY" \
            --advertise-tags="$TAGS" \
            --hostname="$TS_HOSTNAME" \
            --accept-routes \
            --ssh
    else
        warn "No --tailscale-auth-key — Tailscale not registered."
        warn ""
        warn "To register manually:"
        warn "  1. Mint an auth key at https://login.tailscale.com/admin/settings/keys"
        warn "  2. Pre-approve tags: $TAGS"
        warn "  3. Run on the Pi:"
        warn "       sudo tailscale up \\"
        warn "         --auth-key=tskey-... \\"
        warn "         --advertise-tags='$TAGS' \\"
        warn "         --hostname='$TS_HOSTNAME' \\"
        warn "         --accept-routes --ssh"
        warn ""
        warn "Do NOT include tag:maintenance — that's added later via the"
        warn "Tailscale admin web UI on demand. See"
        warn "docs/companion/guides/maintenance-access.md."
    fi
fi

# ─────────────────────────────────────────────────────────────────────
# Final status
# ─────────────────────────────────────────────────────────────────────

PI_IP="$(hostname -I | awk '{print $1}')"
cat <<EOF

═══════════════════════════════════════════════════════════════════
  Companion vanilla install complete

  Site            : $SITE
  Build           : $COMPANION_BUILD
  Install method  : bitfocus/companion-pi (upstream)
  Companion path  : /opt/companion
  Env file        : $ENV_FILE
  systemd drop-in : $DROPIN_FILE
  Tailscale host  : $TS_HOSTNAME
  Web UI (LAN)    : http://$PI_IP:8000
$(if [[ $INSTALL_TAILSCALE -eq 1 ]]; then
  echo "  Web UI (TS)     : http://$TS_HOSTNAME.<tailnet>.ts.net:8000  (only when tag:maintenance enabled)"
fi)

  Next steps:
    1. Edit $ENV_FILE to fill credentials.
    2. sudo systemctl restart companion   (pick up env changes)
    3. Open http://$PI_IP:8000 in browser. Pair Stream Decks via
       Surfaces tab.
    4. Import seed config: Settings → Import/Export → Import →
       seed-${SITE}.companionconfig (generate via
       apps/companion/scripts/seed-export.py --site $SITE --rewrite-hosts).
    5. Verify connections green. Walk Phase 1 of live-test runbook.

  Operational:
    Logs            : sudo journalctl -u companion -f
    Restart         : sudo systemctl restart companion
    Update          : sudo companion-update           # companion-pi tool
    Companion CLI   : sudo /usr/local/sbin/companion-help

  Tailscale state (default-deny):
    NO inbound from your laptop until tag:maintenance is added via
    https://login.tailscale.com/admin/machines  (find $TS_HOSTNAME →
    edit tags → add tag:maintenance → save). See
    docs/companion/guides/maintenance-access.md.
═══════════════════════════════════════════════════════════════════
EOF
