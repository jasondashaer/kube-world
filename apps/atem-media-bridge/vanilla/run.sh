#!/usr/bin/env bash
# Resolve node at runtime (handles fnm layout where the bin path
# changes by version) and exec bridge.js. Lets the systemd unit stay
# stable across node-version bumps.
set -euo pipefail
for candidate in /opt/fnm/node-versions/*/installation/bin/node /usr/bin/node /usr/local/bin/node; do
    if [[ -x "$candidate" ]]; then
        exec "$candidate" /opt/atem-media-bridge/bridge.js
    fi
done
echo "node binary not found" >&2
exit 127
