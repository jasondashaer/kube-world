#!/usr/bin/env bash
#===============================================================================
# Finalize Rancher OIDC — run AFTER completing the browser-based enable step.
#
# This script:
#   1. Verifies OIDC is actually enabled in Rancher
#   2. Maps Zitadel "admin" role → Rancher Admin
#   3. Maps Zitadel "user" role → Rancher Standard User
#   4. Verifies the mappings work
#
# Prerequisites:
#   - Rancher running with Generic OIDC enabled (completed via browser)
#   - KUBECONFIG pointing at the central cluster
#   - Zitadel seed state file at /tmp/zitadel-seed.state
#
# Usage:
#   ./scripts/finalize-oidc.sh
#   KUBECONFIG=~/.kube/pi-config ./scripts/finalize-oidc.sh
#===============================================================================
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OIDC-FINALIZE]${NC} $*"; }
warn()  { echo -e "${YELLOW}[OIDC-FINALIZE]${NC} $*"; }
error() { echo -e "${RED}[OIDC-FINALIZE]${NC} $*" >&2; }

DOMAIN="${DOMAIN:-kubew.dev}"
RANCHER_BOOTSTRAP_PASSWORD="${RANCHER_BOOTSTRAP_PASSWORD:-}"

# Source .env.bootstrap if available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
if [[ -f "${REPO_ROOT}/.env.bootstrap" ]]; then
    source "${REPO_ROOT}/.env.bootstrap"
fi

# Ensure KUBECONFIG is set
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/pi-config}"

#===============================================================================
# Step 1: Verify OIDC is enabled
#===============================================================================
log "Checking if Rancher Generic OIDC is enabled..."

OIDC_ENABLED=$(kubectl get authconfig genericoidc -o jsonpath='{.enabled}' 2>/dev/null || echo "false")

if [[ "$OIDC_ENABLED" != "true" ]]; then
    error "Generic OIDC is NOT enabled in Rancher."
    error ""
    error "Please complete the browser step first:"
    error "  1. Open https://rancher.${DOMAIN}"
    error "  2. Login locally → Auth Provider → Generic OIDC"
    error "  3. Paste the Client Secret"
    error "  4. Switch Endpoints to 'Specify'"
    error "  5. Click 'Enable' → login via Zitadel"
    error ""
    error "Then re-run this script."
    exit 1
fi

log "Generic OIDC is enabled ✓"

#===============================================================================
# Step 2: Get Rancher API access via port-forward
#===============================================================================
log "Connecting to Rancher API..."

local_port=18490
kubectl -n cattle-system port-forward svc/rancher ${local_port}:443 > /dev/null 2>&1 &
PF_PID=$!
sleep 3

cleanup() {
    kill $PF_PID 2>/dev/null || true
}
trap cleanup EXIT

RANCHER_URL="https://localhost:${local_port}"

# Login
if [[ -z "$RANCHER_BOOTSTRAP_PASSWORD" ]]; then
    error "RANCHER_BOOTSTRAP_PASSWORD not set. Source .env.bootstrap first."
    exit 1
fi

TOKEN=$(curl -sk -X POST -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"${RANCHER_BOOTSTRAP_PASSWORD}\",\"responseType\":\"json\"}" \
    "${RANCHER_URL}/v3-public/localProviders/local?action=login" | jq -r '.token' 2>/dev/null || echo "")

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    error "Could not login to Rancher. Check RANCHER_BOOTSTRAP_PASSWORD."
    exit 1
fi

log "Rancher API connected ✓"

#===============================================================================
# Step 3: Configure group → role mappings
#===============================================================================
log "Configuring group-to-role mappings..."

# Helper to create a GlobalRoleBinding
create_grb() {
    local group_name="$1"
    local role_id="$2"
    local label="$3"

    # Check if binding already exists
    local existing
    existing=$(curl -sk -H "Authorization: Bearer ${TOKEN}" \
        "${RANCHER_URL}/v3/globalRoleBindings" 2>/dev/null | \
        jq -r ".data[] | select(.groupPrincipalId == \"genericoidc_group://${group_name}\") | .id" 2>/dev/null || echo "")

    if [[ -n "$existing" ]]; then
        log "  ${label}: already mapped (${existing})"
        return 0
    fi

    local resp
    resp=$(curl -sk -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        "${RANCHER_URL}/v3/globalRoleBindings" \
        -d "{
            \"globalRoleId\": \"${role_id}\",
            \"groupPrincipalId\": \"genericoidc_group://${group_name}\"
        }" 2>/dev/null)

    local id
    id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null || echo "")
    if [[ -n "$id" ]]; then
        log "  ${label}: mapped ✓ (${id})"
    else
        warn "  ${label}: mapping may have failed"
        warn "  Response: $(echo "$resp" | head -c 200)"
    fi
}

# Map Zitadel "admin" role → Rancher Admin
create_grb "admin" "admin" "admin → Rancher Admin"

# Map Zitadel "user" role → Rancher Standard User
create_grb "user" "user" "user → Rancher Standard User"

#===============================================================================
# Step 4: Verify
#===============================================================================
log ""
log "Verifying configuration..."

echo ""
log "Auth provider status:"
kubectl get authconfig genericoidc -o jsonpath='  enabled={.enabled} issuer={.issuer}' 2>/dev/null
echo ""

log "Global role bindings:"
curl -sk -H "Authorization: Bearer ${TOKEN}" "${RANCHER_URL}/v3/globalRoleBindings" 2>/dev/null | \
    jq -r '.data[] | select(.groupPrincipalId != null) | select(.groupPrincipalId | test("genericoidc")) | "  \(.groupPrincipalId) → \(.globalRoleId)"' 2>/dev/null || true

echo ""
log "=============================================="
log "  Rancher OIDC Finalization Complete"
log "=============================================="
log ""
log "  SSO login: https://rancher.${DOMAIN}"
log "  Identity:  https://auth.${DOMAIN}"
log ""
log "  Group mappings:"
log "    Zitadel 'admin' → Rancher Admin"
log "    Zitadel 'user'  → Rancher Standard User"
log ""
log "  Users with the 'admin' role in Zitadel will"
log "  automatically get Rancher Admin access on SSO login."
log "=============================================="
