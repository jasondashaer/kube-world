#!/usr/bin/env bash
# Companion Satellite install for the home Mac (or any laptop where you
# want a Stream Deck that mirrors a remote production Companion).
#
# Architecture:
#   Your home Mac:        Companion Satellite (this install)
#   Your home Stream Deck: connected to the Mac via USB or LAN
#   Production Pi:        Companion brain (full install at YIBC/Saitama)
#
#   Mac → Tailscale → Production Pi:16622   (satellite tunnel)
#   Stream Deck → USB → Mac                  (local)
#
# Requires `tag:maintenance` on the production Pi for the satellite
# tunnel to connect — production access is default-deny otherwise.
# See docs/companion/guides/maintenance-access.md.
#
# Usage:
#   ./install.sh                                       # interactive
#   ./install.sh --target pi-yibc.<tailnet>.ts.net     # explicit target
#   ./install.sh --version 1.10.0                     # pin satellite ver

set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# Args + defaults
# ─────────────────────────────────────────────────────────────────

SAT_VERSION="1.10.0"
TARGET_HOST=""
TARGET_PORT="16622"
INSTALL_DIR="/usr/local/bitfocus-companion-satellite"
PLIST="/Library/LaunchDaemons/io.bitfocus.companion-satellite.plist"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  SAT_VERSION="$2"; shift 2 ;;
        --target)   TARGET_HOST="$2"; shift 2 ;;
        --port)     TARGET_PORT="$2"; shift 2 ;;
        --install-dir) INSTALL_DIR="$2"; shift 2 ;;
        --help|-h)  sed -n '2,/^set -euo pipefail/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ "$(uname)" != "Darwin" ]]; then
    echo "ERROR: This installer targets macOS. For Linux, see Bitfocus" >&2
    echo "       docs at https://bitfocus.io/companion-satellite" >&2
    exit 1
fi

if [[ $EUID -ne 0 ]]; then
    echo "Re-running with sudo..."
    exec sudo bash "$0" "$@"
fi

ARCH="$(uname -m)"
case "$ARCH" in
    arm64) SAT_ARCH="arm64" ;;
    x86_64) SAT_ARCH="x64" ;;
    *) echo "ERROR: unsupported arch $ARCH" >&2; exit 1 ;;
esac

GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
log()  { printf '%s[satellite]%s %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n'      "$YELLOW" "$RESET" "$*"; }

# ─────────────────────────────────────────────────────────────────
# Resolve target host
# ─────────────────────────────────────────────────────────────────

if [[ -z "$TARGET_HOST" ]]; then
    cat <<EOF
Companion Satellite needs to know which production Companion to mirror.

Common targets (replace <tailnet> with your tailnet name —
see https://login.tailscale.com/admin/dns):
  pi-yibc.<tailnet>.ts.net
  pi-saitama.<tailnet>.ts.net

You can change this later by editing $INSTALL_DIR/satellite-config.yaml.

EOF
    read -rp "Target host: " TARGET_HOST
    if [[ -z "$TARGET_HOST" ]]; then
        echo "ERROR: target host required" >&2
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────────
# Download Satellite
# ─────────────────────────────────────────────────────────────────

if [[ -d "$INSTALL_DIR" ]] && [[ -f "$INSTALL_DIR/.installed-version" ]] && \
   [[ "$(cat "$INSTALL_DIR/.installed-version")" == "$SAT_VERSION" ]]; then
    log "Satellite $SAT_VERSION already installed — skipping download"
else
    log "Downloading Satellite $SAT_VERSION ($SAT_ARCH)..."
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"

    # Bitfocus packages Satellite as a signed .pkg on macOS, but for
    # programmatic install we use the tarball + manual launchd plist.
    URL="https://github.com/bitfocus/companion-satellite/releases/download/v${SAT_VERSION}/companion-satellite-${SAT_VERSION}-mac-${SAT_ARCH}.tar.gz"
    cd /tmp
    curl -fsSL -o satellite.tar.gz "$URL" || {
        echo "Failed to download. Verify the version exists at https://github.com/bitfocus/companion-satellite/releases" >&2
        exit 1
    }
    tar -xzf satellite.tar.gz -C "$INSTALL_DIR" --strip-components=1
    rm satellite.tar.gz
    echo "$SAT_VERSION" > "$INSTALL_DIR/.installed-version"
    log "Installed at $INSTALL_DIR"
fi

# ─────────────────────────────────────────────────────────────────
# Config file
# ─────────────────────────────────────────────────────────────────

CONFIG="$INSTALL_DIR/satellite-config.yaml"

if [[ ! -f "$CONFIG" ]] || [[ "${OVERWRITE_CONFIG:-0}" == "1" ]]; then
    log "Writing config → $CONFIG"
    cat > "$CONFIG" <<EOF
# Companion Satellite config — edit + restart launchd to apply.
# Restart: sudo launchctl kickstart -k system/io.bitfocus.companion-satellite

# Companion brain to connect to. Use the Tailscale MagicDNS hostname
# of the production Pi. Connection only works when tag:maintenance is
# applied to that Pi (default-deny otherwise).
host: $TARGET_HOST
port: $TARGET_PORT

# Stream Deck connections — auto-detect USB by default.
# Add network surfaces here if needed (Stream Deck Network module
# devices not on this Mac).
# stream_decks:
#   - host: 192.168.x.y
#     port: 5343

installation_id: $(uuidgen)

# Restart on failure with backoff
keep_alive: true
EOF
else
    log "Existing config preserved — re-run with OVERWRITE_CONFIG=1 to replace"
fi

# ─────────────────────────────────────────────────────────────────
# launchd plist
# ─────────────────────────────────────────────────────────────────

log "Installing launchd plist → $PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>io.bitfocus.companion-satellite</string>
  <key>ProgramArguments</key>
  <array>
    <string>$INSTALL_DIR/companion-satellite</string>
    <string>--config</string>
    <string>$CONFIG</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>StandardOutPath</key>
  <string>/var/log/companion-satellite.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/companion-satellite.err</string>
  <key>ThrottleInterval</key>
  <integer>10</integer>
</dict>
</plist>
EOF

chmod 644 "$PLIST"
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

log "Satellite started under launchd."

# ─────────────────────────────────────────────────────────────────
# Status
# ─────────────────────────────────────────────────────────────────

cat <<EOF

═══════════════════════════════════════════════════════════════════
  Companion Satellite installed.

  Target  : $TARGET_HOST:$TARGET_PORT
  Config  : $CONFIG
  Logs    : tail -f /var/log/companion-satellite.log
  Restart : sudo launchctl kickstart -k system/io.bitfocus.companion-satellite
  Stop    : sudo launchctl unload $PLIST
  Start   : sudo launchctl load $PLIST

  Connection state:
    - Will attempt to connect immediately.
    - Will FAIL until the target Pi has tag:maintenance applied via
      Tailscale admin (https://login.tailscale.com/admin/machines).
    - When tag:maintenance is applied, satellite reconnects within
      ~30 seconds (auto-retry on backoff).

  Stream Decks:
    - Plug a Stream Deck into this Mac (USB).
    - Satellite registers it with the production Companion brain.
    - The Stream Deck face will mirror the production Stream Deck
      pages and reflect live state (mute indicators, active scenes,
      countdown).
    - Pressing buttons on this Stream Deck fires actions on the
      production AV system. Use carefully.

  Switching targets (e.g. YIBC → Saitama):
    sudo \$EDITOR $CONFIG     # change 'host:'
    sudo launchctl kickstart -k system/io.bitfocus.companion-satellite
═══════════════════════════════════════════════════════════════════

EOF
