#!/usr/bin/env bash
#===============================================================================
# Companion deploy — YIBC (vanilla CompanionPi, no k3s, no Flux)
#
# Generates the YIBC-only .companionconfig from
# apps/companion/config/sites/yibc/ and imports it directly into the
# CompanionPi instance running on the YIBC Pi via tRPC over Tailscale.
#
# Usage:
#   ./apps/companion/scripts/deploy-yibc.sh                   # generate + import
#   ./apps/companion/scripts/deploy-yibc.sh --generate-only   # build .companionconfig, don't push
#   ./apps/companion/scripts/deploy-yibc.sh --url http://yibc.tailab53c1.ts.net:8000
#
# Env required for credential substitution (loaded from .env.yibc if present):
#   PROPRESENTER_PASSWORD_YIBC
#   OBS_PASSWORD_YIBC
#   SPOTIFY_CLIENT_ID
#   SPOTIFY_CLIENT_SECRET
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEFAULT_URL="http://yibc.tailab53c1.ts.net:8000"
URL="$DEFAULT_URL"
GENERATE_ONLY=false

for arg in "$@"; do
    case "$arg" in
        --url=*)        URL="${arg#--url=}" ;;
        --url)          shift; URL="${1:-$DEFAULT_URL}" ;;
        --generate-only) GENERATE_ONLY=true ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^#//'
            exit 0
            ;;
    esac
done

if [[ -f "$REPO_ROOT/.env.yibc" ]]; then
    # shellcheck disable=SC1091
    set -a; source "$REPO_ROOT/.env.yibc"; set +a
fi

export COMPANION_SITE=yibc
export COMPANION_CONFIG_DIR="$REPO_ROOT/apps/companion/config"

# Per-connection cert/pair-state backup file (gitignored). Loaded as
# fallback before the live cert-preserve snapshot, refreshed after
# every successful import. See companion-deploy.py
# load_preserved_state_from_file / save_preserved_state_to_file.
CERT_BACKUP="$REPO_ROOT/.companion-state/yibc-preserved.json"

cd "$REPO_ROOT"

echo "── generating .companionconfig (site=yibc) ──"
python3 apps/companion/scripts/companion-deploy.py --site yibc generate

if [[ "$GENERATE_ONLY" == "true" ]]; then
    echo "── generate-only mode; skipping import ──"
    exit 0
fi

echo "── probing $URL ──"
if ! curl -sS -o /dev/null -w "  http=%{http_code}\n" --max-time 5 "$URL/"; then
    echo "Companion HTTP probe failed at $URL — is yibc Pi reachable on Tailscale?"
    exit 3
fi

echo "── importing via tRPC ──"
python3 apps/companion/scripts/companion-deploy.py --site yibc import \
    --url "$URL" \
    --cert-backup-file "$CERT_BACKUP"

echo "── done ──"
