#!/usr/bin/env bash
#===============================================================================
# atem-media-bridge installer (vanilla / msn-saitama)
#
# Drops bridge.js + package.json under /opt/atem-media-bridge/, npm-installs
# atem-connection + sharp + yaml, creates the service user, sets up
# /opt/atem-media/ for graphics, writes a sample slots.yaml at
# /etc/atem-media-bridge/, and enables the systemd unit.
#
# Usage:
#   sudo ./install.sh <atem-host>
#
# Re-runs are safe — files get re-copied + npm install --omit=dev re-applied;
# user/dir creation is idempotent.
#===============================================================================
set -euo pipefail

ATEM_HOST="${1:-10.1.1.179}"

if [[ $EUID -ne 0 ]]; then
    echo "must run as root (sudo ./install.sh <atem-host>)" >&2
    exit 1
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR=/opt/atem-media-bridge
MEDIA_DIR=/opt/atem-media
CONFIG_DIR=/etc/atem-media-bridge
SVC_USER=atem-media-bridge

# Resolve node + npm. CompanionPi ships node 22 via fnm under /opt/fnm/.
# Prefer that; fall back to system node, otherwise apt-get.
NODE_BIN=""
NPM_BIN=""
for candidate in \
    /opt/fnm/node-versions/*/installation/bin \
    /usr/local/bin \
    /usr/bin \
; do
    if [[ -x "$candidate/node" && -x "$candidate/npm" ]]; then
        NODE_BIN="$candidate/node"
        NPM_BIN="$candidate/npm"
        break
    fi
done

if [[ -z "$NODE_BIN" ]]; then
    echo "── apt deps (node, ca-certs) ──"
    apt-get update -qq
    apt-get install -y --no-install-recommends nodejs npm
    NODE_BIN=$(command -v node || true)
    NPM_BIN=$(command -v npm || true)
fi

if [[ -z "$NODE_BIN" || -z "$NPM_BIN" ]]; then
    echo "node/npm not found and apt install did not produce them" >&2
    exit 2
fi
echo "── using node: $NODE_BIN ──"

NODE_MAJOR=$("$NODE_BIN" -p 'process.versions.node.split(".")[0]')
if (( NODE_MAJOR < 20 )); then
    echo "WARN: node $NODE_MAJOR detected; atem-connection wants node >=20" >&2
fi

echo "── service user ──"
if ! id -u "$SVC_USER" >/dev/null 2>&1; then
    useradd --system --home "$INSTALL_DIR" --shell /usr/sbin/nologin "$SVC_USER"
fi

echo "── install dirs ──"
install -d -m 0755 -o "$SVC_USER" -g "$SVC_USER" "$INSTALL_DIR"
install -d -m 0755 -o "$SVC_USER" -g "$SVC_USER" "$MEDIA_DIR"
install -d -m 0755 "$CONFIG_DIR"

echo "── copy bridge.js + package.json + run.sh ──"
install -m 0644 -o "$SVC_USER" -g "$SVC_USER" \
    "$SRC_DIR/bridge.js" "$INSTALL_DIR/bridge.js"
install -m 0644 -o "$SVC_USER" -g "$SVC_USER" \
    "$SRC_DIR/package.json" "$INSTALL_DIR/package.json"
install -m 0755 -o "$SVC_USER" -g "$SVC_USER" \
    "$SRC_DIR/vanilla/run.sh" "$INSTALL_DIR/run.sh"

echo "── npm install (production) ──"
cd "$INSTALL_DIR"
# Run as service user with explicit PATH to the resolved node.
NODE_DIR=$(dirname "$NODE_BIN")
sudo -u "$SVC_USER" -H env PATH="$NODE_DIR:/usr/bin:/bin" \
    "$NPM_BIN" install --omit=dev --no-audit --no-fund

echo "── seed config (only if missing) ──"
if [[ ! -f "$CONFIG_DIR/slots.yaml" ]]; then
    sed "s|atem_host: 10\\.1\\.1\\.179|atem_host: ${ATEM_HOST}|" \
        "$SRC_DIR/slots.yaml.example" > "$CONFIG_DIR/slots.yaml"
    chmod 0644 "$CONFIG_DIR/slots.yaml"
    echo "  wrote $CONFIG_DIR/slots.yaml"
else
    echo "  $CONFIG_DIR/slots.yaml already exists; leaving as-is"
fi

echo "── systemd unit ──"
install -m 0644 "$SRC_DIR/vanilla/atem-media-bridge.service" \
    /etc/systemd/system/atem-media-bridge.service
systemctl daemon-reload
systemctl enable atem-media-bridge.service

echo
echo "── done ──"
echo "Drop graphics under $MEDIA_DIR/ (chown $SVC_USER:$SVC_USER)."
echo "Edit slots in $CONFIG_DIR/slots.yaml, then:"
echo "  sudo systemctl restart atem-media-bridge"
echo "  journalctl -u atem-media-bridge -f"
