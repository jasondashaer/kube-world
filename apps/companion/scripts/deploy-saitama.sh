#!/usr/bin/env bash
#===============================================================================
# Companion deploy — Saitama (vanilla CompanionPi, no k3s, no Flux)
#
# Generates the Saitama-only .companionconfig from
# apps/companion/config/sites/saitama/ and imports it directly into the
# CompanionPi instance running on msn-saitama via tRPC. Reachable from
# any workstation on the Tailscale tailnet.
#
# Usage:
#   ./apps/companion/scripts/deploy-saitama.sh                   # generate + import
#   ./apps/companion/scripts/deploy-saitama.sh --generate-only   # build .companionconfig, don't push
#   ./apps/companion/scripts/deploy-saitama.sh --url http://msn-saitama.tailab53c1.ts.net:8000
#
# Env required for credential substitution (loaded from .env.saitama if present):
#   PROPRESENTER_PASSWORD_SAITAMA
#   SPOTIFY_CLIENT_ID_SAITAMA
#   SPOTIFY_CLIENT_SECRET_SAITAMA
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEFAULT_URL="http://msn-saitama.tailab53c1.ts.net:8000"
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

# Source .env.saitama if it exists (local dev convenience).
if [[ -f "$REPO_ROOT/.env.saitama" ]]; then
    # shellcheck disable=SC1091
    set -a; source "$REPO_ROOT/.env.saitama"; set +a
fi

export COMPANION_SITE=saitama
export COMPANION_CONFIG_DIR="$REPO_ROOT/apps/companion/config"

cd "$REPO_ROOT"

echo "── generating .companionconfig (site=saitama) ──"
python3 apps/companion/scripts/companion-deploy.py --site saitama generate

if [[ "$GENERATE_ONLY" == "true" ]]; then
    echo "── generate-only mode; skipping import ──"
    exit 0
fi

# Probe before import so we fail with a clear message instead of inside tRPC.
echo "── probing $URL ──"
if ! curl -sS -o /dev/null -w "  http=%{http_code}\n" --max-time 5 "$URL/"; then
    echo "Companion HTTP probe failed at $URL — is msn-saitama reachable on Tailscale?"
    exit 3
fi

echo "── importing via tRPC ──"
python3 apps/companion/scripts/companion-deploy.py --site saitama import --url "$URL"

echo "── done ──"
