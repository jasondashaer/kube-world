#!/usr/bin/env bash
# Vanilla Companion install for production sites (YIBC, Saitama).
#
# Idempotent: safe to re-run. Does NOT touch existing Companion data —
# install only sets up the systemd service + dependencies.
#
# Usage (run on the Pi):
#   curl -fsSL https://raw.githubusercontent.com/jasondashaer/kube-world/main/deploy/vanilla/install.sh | sudo bash -s -- --site <site_name>
#
# Or local checkout:
#   sudo ./install.sh --site yibc
#
# Args:
#   --site <name>      Required. Site identifier (yibc | saitama | other).
#                      Determines which env file to load.
#   --version <ver>    Optional. Companion version to install
#                      (default: 4.2.0 — matches development environment).
#   --user <user>      Optional. Local user account to own Companion data
#                      (default: companion).
#   --data-dir <path>  Optional. Companion data directory
#                      (default: /var/lib/companion).
#   --no-tailscale     Skip Tailscale install (you'll handle remote access
#                      another way, e.g. Ubiquiti VPN).
#   --tailscale-auth-key <KEY>
#                      Pre-authorize Tailscale registration. Mint this in
#                      the Tailscale admin console with the correct base
#                      tags pre-approved:
#                        tag:companion, tag:env-prod, tag:site-<site>
#                      Do NOT include tag:maintenance — that's added later
#                      via web UI on demand.
#                      If omitted: Tailscale installs but doesn't auto-
#                      register; operator runs `sudo tailscale up` later.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
# Args + defaults
# ─────────────────────────────────────────────────────────────────────

SITE=""
COMPANION_VERSION="4.2.0"
COMPANION_USER="companion"
COMPANION_DATA="/var/lib/companion"
INSTALL_TAILSCALE=1
TAILSCALE_AUTH_KEY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site) SITE="$2"; shift 2 ;;
        --version) COMPANION_VERSION="$2"; shift 2 ;;
        --user) COMPANION_USER="$2"; shift 2 ;;
        --data-dir) COMPANION_DATA="$2"; shift 2 ;;
        --no-tailscale) INSTALL_TAILSCALE=0; shift ;;
        --tailscale-auth-key) TAILSCALE_AUTH_KEY="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,/^set -euo pipefail/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$SITE" ]]; then
    echo "ERROR: --site is required (e.g. --site yibc)" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root (sudo)" >&2
    exit 1
fi

# Detect arch — Companion releases ARM64 .tgz for Pi 4/5
ARCH="$(uname -m)"
case "$ARCH" in
    aarch64|arm64) COMPANION_ARCH="arm64" ;;
    x86_64) COMPANION_ARCH="x64" ;;
    *) echo "ERROR: unsupported arch $ARCH" >&2; exit 1 ;;
esac

log() { printf '\033[32m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[warn]\033[0m %s\n' "$*"; }
err() { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; }

# ─────────────────────────────────────────────────────────────────────
# Resolve repo root (for systemd unit + env files when running locally)
# ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "")"
SITE_DIR="$SCRIPT_DIR/site/$SITE"

# When run via curl|bash, SCRIPT_DIR points at /tmp/<random> with no
# repo content. Detect this and clone shallow into /opt/kube-world.
if [[ ! -d "$SITE_DIR" ]]; then
    log "Site directory not found locally; cloning kube-world to /opt/kube-world..."
    apt-get install -y git
    rm -rf /opt/kube-world
    git clone --depth=1 https://github.com/jasondashaer/kube-world.git /opt/kube-world
    REPO_ROOT="/opt/kube-world"
    SITE_DIR="$REPO_ROOT/deploy/vanilla/site/$SITE"
    SCRIPT_DIR="$REPO_ROOT/deploy/vanilla"
fi

if [[ ! -d "$SITE_DIR" ]]; then
    err "Site '$SITE' not found at $SITE_DIR"
    err "Expected one of: $(ls "$SCRIPT_DIR/site/" 2>/dev/null | tr '\n' ' ')"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────
# System dependencies
# ─────────────────────────────────────────────────────────────────────

log "Updating apt..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl wget tar libusb-1.0-0 libudev-dev avahi-daemon

# ─────────────────────────────────────────────────────────────────────
# User + data directory
# ─────────────────────────────────────────────────────────────────────

if ! id -u "$COMPANION_USER" >/dev/null 2>&1; then
    log "Creating user $COMPANION_USER..."
    useradd --system --home-dir "$COMPANION_DATA" --shell /usr/sbin/nologin \
        --groups plugdev,dialout "$COMPANION_USER"
else
    log "User $COMPANION_USER already exists — adding to plugdev,dialout"
    usermod -aG plugdev,dialout "$COMPANION_USER"
fi

mkdir -p "$COMPANION_DATA"
chown -R "$COMPANION_USER:$COMPANION_USER" "$COMPANION_DATA"
chmod 755 "$COMPANION_DATA"

# ─────────────────────────────────────────────────────────────────────
# Companion binary install
# ─────────────────────────────────────────────────────────────────────

INSTALL_DIR="/opt/companion"
TARBALL="companion-${COMPANION_VERSION}-linux-${COMPANION_ARCH}.tar.gz"
URL="https://github.com/bitfocus/companion/releases/download/v${COMPANION_VERSION}/${TARBALL}"

if [[ -f "$INSTALL_DIR/.installed-version" ]] && \
   [[ "$(cat "$INSTALL_DIR/.installed-version")" == "$COMPANION_VERSION" ]]; then
    log "Companion $COMPANION_VERSION already installed at $INSTALL_DIR — skipping download"
else
    log "Downloading Companion $COMPANION_VERSION ($COMPANION_ARCH)..."
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    cd /tmp
    curl -fsSL -o "$TARBALL" "$URL" || {
        err "Failed to download Companion release."
        err "Verify URL: $URL"
        exit 1
    }
    tar -xzf "$TARBALL" -C "$INSTALL_DIR" --strip-components=1
    rm "$TARBALL"
    echo "$COMPANION_VERSION" > "$INSTALL_DIR/.installed-version"
    log "Installed Companion $COMPANION_VERSION at $INSTALL_DIR"
fi

# udev rule for Stream Deck access without root
UDEV_RULE="/etc/udev/rules.d/50-streamdeck.rules"
if [[ ! -f "$UDEV_RULE" ]]; then
    log "Installing Stream Deck udev rule..."
    cat > "$UDEV_RULE" <<'EOF'
# Elgato Stream Deck — non-root access for plugdev group
SUBSYSTEM=="usb", ATTRS{idVendor}=="0fd9", MODE="0660", GROUP="plugdev"
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0fd9", MODE="0660", GROUP="plugdev"
EOF
    udevadm control --reload-rules
    udevadm trigger
fi

# ─────────────────────────────────────────────────────────────────────
# Site env file
# ─────────────────────────────────────────────────────────────────────

ENV_FILE="/etc/default/companion"
if [[ ! -f "$ENV_FILE" ]]; then
    log "Installing site env file from $SITE_DIR/.env.example..."
    if [[ -f "$SITE_DIR/.env.example" ]]; then
        cp "$SITE_DIR/.env.example" "$ENV_FILE"
        chmod 640 "$ENV_FILE"
        chown root:"$COMPANION_USER" "$ENV_FILE"
        warn "Edit $ENV_FILE to fill in real credentials (Spotify, OBS, etc.)"
    else
        warn "No .env.example for site $SITE — creating empty $ENV_FILE"
        touch "$ENV_FILE"
        chmod 640 "$ENV_FILE"
        chown root:"$COMPANION_USER" "$ENV_FILE"
    fi
else
    log "Env file $ENV_FILE already exists — leaving alone"
fi

# ─────────────────────────────────────────────────────────────────────
# systemd unit
# ─────────────────────────────────────────────────────────────────────

UNIT_SRC="$SCRIPT_DIR/companion.service"
UNIT_DST="/etc/systemd/system/companion.service"

if [[ ! -f "$UNIT_SRC" ]]; then
    err "Missing systemd unit at $UNIT_SRC"
    exit 1
fi

# Substitute variables into the unit file
sed \
    -e "s|@COMPANION_USER@|$COMPANION_USER|g" \
    -e "s|@COMPANION_DATA@|$COMPANION_DATA|g" \
    -e "s|@INSTALL_DIR@|$INSTALL_DIR|g" \
    "$UNIT_SRC" > "$UNIT_DST"

systemctl daemon-reload

if systemctl is-enabled companion >/dev/null 2>&1; then
    log "companion.service already enabled — restarting"
    systemctl restart companion
else
    log "Enabling + starting companion.service..."
    systemctl enable --now companion
fi

# ─────────────────────────────────────────────────────────────────────
# Tailscale (optional)
# ─────────────────────────────────────────────────────────────────────

if [[ $INSTALL_TAILSCALE -eq 1 ]]; then
    if ! command -v tailscale >/dev/null 2>&1; then
        log "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    else
        log "Tailscale already installed — leaving alone"
    fi

    # Build the tag set from --site argument. These are the BASE tags
    # the Pi advertises every time it brings up Tailscale. Maintenance
    # is added separately via the Tailscale admin console; never auto-
    # applied by the Pi to itself (security boundary).
    TAGS="tag:companion,tag:env-prod,tag:site-${SITE}"

    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        # Auth key minted in https://login.tailscale.com/admin/settings/keys
        # MUST have the matching tags pre-authorized at mint time
        # (Tailscale rejects --advertise-tags that the auth key isn't
        # authorized to apply).
        log "Registering Tailscale with tags: $TAGS"
        tailscale up \
            --auth-key="$TAILSCALE_AUTH_KEY" \
            --advertise-tags="$TAGS" \
            --hostname="pi-${SITE}" \
            --accept-routes \
            --ssh
    else
        warn "No --tailscale-auth-key — Tailscale not registered yet."
        warn ""
        warn "To register manually:"
        warn "  1. Mint an auth key at https://login.tailscale.com/admin/settings/keys"
        warn "  2. Pre-approve tags: $TAGS"
        warn "  3. Run on the Pi:"
        warn "       sudo tailscale up \\"
        warn "         --auth-key=tskey-... \\"
        warn "         --advertise-tags='$TAGS' \\"
        warn "         --hostname='pi-${SITE}' \\"
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
  Version         : $COMPANION_VERSION ($COMPANION_ARCH)
  Install dir     : $INSTALL_DIR
  Data dir        : $COMPANION_DATA (owned by $COMPANION_USER)
  Env file        : $ENV_FILE (edit to set credentials)
  Web UI          : http://$PI_IP:8000

  Next steps:
    1. Edit $ENV_FILE to fill Spotify token, OBS WS password, etc.
       sudo systemctl restart companion   # to pick up env changes
    2. Open http://$PI_IP:8000 in a browser. Add your Stream Decks
       (USB or network).
    3. Import the site seed config:
       Settings → Import/Export → Import → choose the
       seed-<SITE>.companionconfig file from the kube-world repo
       (apps/companion/config/companion.companionconfig — generated by
       seed-export.py).
    4. Verify each connection turns green. Verify Stream Deck shows
       expected pages.

  Logs            : sudo journalctl -u companion -f
  Restart         : sudo systemctl restart companion
  Stop            : sudo systemctl stop companion
═══════════════════════════════════════════════════════════════════
EOF
