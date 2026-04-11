#!/usr/bin/env bash
#===============================================================================
# Generate a Long-Lived Access Token for the Home Assistant mobile app.
#
# The HA iOS/Android app can't handle OIDC SSO properly — the webview
# gets stuck on the OIDC component's finish screen and never returns
# a callback to the app. Instead, we generate an LLT that you paste
# into the app during server setup.
#
# This script:
#   1. Logs into HA via the local admin credentials
#   2. Creates a 10-year LLT via the WebSocket API
#   3. Prints it for you to copy
#
# Prerequisites:
#   - .env.bootstrap sourced (has RANCHER_BOOTSTRAP_PASSWORD)
#   - HA running and reachable
#   - Local admin user exists (created by the init container)
#
# Usage:
#   source .env.bootstrap
#   ./scripts/ha-mobile-token.sh
#   ./scripts/ha-mobile-token.sh --name "Jackson iPhone" --days 3650
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source bootstrap env if available
if [[ -f "${REPO_ROOT}/.env.bootstrap" ]]; then
    source "${REPO_ROOT}/.env.bootstrap"
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[HA-TOKEN]${NC} $*"; }
warn()  { echo -e "${YELLOW}[HA-TOKEN]${NC} $*"; }
error() { echo -e "${RED}[HA-TOKEN]${NC} $*" >&2; }

HA_URL="${HA_URL:-https://ha.edge1.kubew.dev}"
HA_USERNAME="${HA_LOCAL_USERNAME:-admin}"
HA_PASSWORD="${HA_LOCAL_PASSWORD:-${RANCHER_BOOTSTRAP_PASSWORD:-}}"
TOKEN_NAME="iPhone HA App"
TOKEN_DAYS=3650
EDGE_KUBECONFIG="${EDGE_KUBECONFIG:-${HOME}/.kube/pi-edge-1-config}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) TOKEN_NAME="$2"; shift 2 ;;
        --days) TOKEN_DAYS="$2"; shift 2 ;;
        --url) HA_URL="$2"; shift 2 ;;
        --username) HA_USERNAME="$2"; shift 2 ;;
        --password) HA_PASSWORD="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# Usage:/,/^#==/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

if [[ -z "$HA_PASSWORD" ]]; then
    error "HA_PASSWORD not set — source .env.bootstrap or pass --password"
    exit 1
fi

log "Logging into HA as ${HA_USERNAME}..."

# Step 1: Start login flow
FLOW=$(curl -sk -X POST "${HA_URL}/auth/login_flow" \
    -H "Content-Type: application/json" \
    -d "{
        \"client_id\": \"${HA_URL}/\",
        \"handler\": [\"homeassistant\", null],
        \"redirect_uri\": \"${HA_URL}/?auth_callback=1\"
    }")
FLOW_ID=$(echo "$FLOW" | jq -r '.flow_id // empty')
if [[ -z "$FLOW_ID" ]]; then
    error "Failed to start login flow: $FLOW"
    exit 1
fi

# Step 2: Complete with credentials
RESULT=$(curl -sk -X POST "${HA_URL}/auth/login_flow/${FLOW_ID}" \
    -H "Content-Type: application/json" \
    -d "{
        \"username\": \"${HA_USERNAME}\",
        \"password\": \"${HA_PASSWORD}\",
        \"client_id\": \"${HA_URL}/\"
    }")
AUTH_CODE=$(echo "$RESULT" | jq -r '.result // empty')
if [[ -z "$AUTH_CODE" ]]; then
    error "Login failed: $RESULT"
    exit 1
fi

# Step 3: Exchange code for access token
TOKEN_RESP=$(curl -sk -X POST "${HA_URL}/auth/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=authorization_code&code=${AUTH_CODE}&client_id=${HA_URL}/")
ACCESS_TOKEN=$(echo "$TOKEN_RESP" | jq -r '.access_token // empty')
if [[ -z "$ACCESS_TOKEN" ]]; then
    error "Token exchange failed: $TOKEN_RESP"
    exit 1
fi

log "Authenticated ✓"
log "Creating LLT via WebSocket API..."

# Step 4: Create LLT via WebSocket inside the HA pod
# (Running outside the cluster, we can't hit the internal WebSocket URL,
#  so exec into the pod and do it there)
if ! command -v kubectl &>/dev/null; then
    error "kubectl not found — cannot create LLT via pod exec"
    exit 1
fi

LLT=$(KUBECONFIG="$EDGE_KUBECONFIG" kubectl -n home-assistant exec deploy/home-assistant -- \
    python3 -c "
import asyncio, json, websockets
async def create():
    async with websockets.connect('ws://localhost:8123/api/websocket') as ws:
        await ws.recv()  # auth_required
        await ws.send(json.dumps({'type': 'auth', 'access_token': '${ACCESS_TOKEN}'}))
        await ws.recv()  # auth_ok
        await ws.send(json.dumps({
            'id': 1,
            'type': 'auth/long_lived_access_token',
            'client_name': '${TOKEN_NAME}',
            'lifespan': ${TOKEN_DAYS}
        }))
        result = json.loads(await ws.recv())
        if result.get('success'):
            print(result['result'])
        else:
            print('ERROR:', result, file=__import__('sys').stderr)
            exit(1)
asyncio.run(create())
" 2>&1)

if [[ -z "$LLT" || "$LLT" == ERROR* ]]; then
    error "LLT creation failed: $LLT"
    exit 1
fi

echo ""
echo "================================================================"
log "  LONG-LIVED ACCESS TOKEN"
echo "================================================================"
echo "$LLT"
echo "================================================================"
echo ""
log "Token valid for ${TOKEN_DAYS} days (~$((TOKEN_DAYS / 365)) years)"
log "Name: ${TOKEN_NAME}"
echo ""
log "In the HA mobile app:"
log "  1. Add server: ${HA_URL}"
log "  2. When it loads the login page, look for:"
log "     'Enter a Long-Lived Access Token' (or similar)"
log "  3. Paste the token above"
echo ""
