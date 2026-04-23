#!/usr/bin/env bash
#===============================================================================
# Companion Config Sync
#
# Exports the current live Companion configuration and saves it to the
# repo for Git tracking. Run this after making on-the-fly changes in
# the Companion web UI to persist them in version control.
#
# Usage:
#   ./apps/companion/scripts/companion-sync.sh
#   ./apps/companion/scripts/companion-sync.sh --url https://companion.edge1.kubew.dev
#   ./apps/companion/scripts/companion-sync.sh --commit  # auto-commit after export
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
URL="${1:-https://companion.edge1.kubew.dev}"
COMMIT=false

for arg in "$@"; do
    case "$arg" in
        --commit) COMMIT=true ;;
        --url=*) URL="${arg#--url=}" ;;
        https://*) URL="$arg" ;;
    esac
done

echo "Exporting from ${URL}..."

# Download and decompress
curl -sk "${URL}/int/export/full" | python3 -c "
import sys, gzip, json
data = gzip.decompress(sys.stdin.buffer.read())
config = json.loads(data)
json.dump(config, sys.stdout, indent=2)
" > "${CONFIG_DIR}/companion-live.json"

echo "Saved: ${CONFIG_DIR}/companion-live.json"
echo "  Pages: $(python3 -c "import json; d=json.load(open('${CONFIG_DIR}/companion-live.json')); print(len(d.get('pages',{})))")"
echo "  Connections: $(python3 -c "import json; d=json.load(open('${CONFIG_DIR}/companion-live.json')); print(len(d.get('instances',{})))")"

if [[ "$COMMIT" == "true" ]]; then
    cd "$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
    git add "${CONFIG_DIR}/companion-live.json"
    git commit -m "companion: sync live config from Companion"
    echo "Committed to Git"
fi

echo "Done. Review changes with: git diff ${CONFIG_DIR}/companion-live.json"
