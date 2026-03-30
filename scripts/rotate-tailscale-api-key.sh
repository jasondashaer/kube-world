#!/usr/bin/env bash
#===============================================================================
# Tailscale API Key Rotation Helper
#
# Run this after creating a new API key in the Tailscale admin console.
# It validates the new key, updates the K8s secret on the central cluster,
# deletes the old key from Tailscale, and creates a fresh auth key for
# provisioning.
#
# USAGE:
#   ./scripts/rotate-tailscale-api-key.sh <new-api-key>
#   ./scripts/rotate-tailscale-api-key.sh tskey-api-xxxxx-yyyyy
#
# PREREQUISITES:
#   - kubectl context pointing at the central cluster
#   - The old API key still stored in kube-world-secrets (for cleanup)
#
# WHAT IT DOES:
#   1. Validates the new API key against the Tailscale API
#   2. Retrieves the old API key from kube-world-secrets
#   3. Updates kube-world-secrets with the new API key + key ID
#   4. Deletes the old API key from Tailscale
#   5. Creates a fresh 90-day reusable pre-authorized auth key
#   6. Stores the auth key in kube-world-secrets for provisioning
#===============================================================================
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[tailscale]${NC} $*"; }
warn()  { echo -e "${YELLOW}[tailscale]${NC} $*"; }
error() { echo -e "${RED}[tailscale]${NC} $*" >&2; }

TAILSCALE_API="https://api.tailscale.com/api/v2"
SECRET_NAME="kube-world-secrets"
SECRET_NS="default"

#===============================================================================
# Validate input
#===============================================================================
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <new-tailscale-api-key>"
    echo ""
    echo "Create a new API key at: https://login.tailscale.com/admin/settings/keys"
    echo "  - Type: API key (not auth key)"
    echo "  - Scopes: all"
    echo "  - Expiry: 90 days"
    echo "  - Description: kube-world"
    exit 1
fi

NEW_API_KEY="$1"

# Basic format check
if [[ ! "$NEW_API_KEY" =~ ^tskey-api- ]]; then
    error "Key doesn't look like a Tailscale API key (should start with tskey-api-)"
    exit 1
fi

#===============================================================================
# Step 1: Validate the new API key
#===============================================================================
log "Validating new API key..."
DEVICES_RESPONSE=$(curl -sf -u "${NEW_API_KEY}:" "${TAILSCALE_API}/tailnet/-/devices" 2>/dev/null || echo "")
if [[ -z "$DEVICES_RESPONSE" ]]; then
    error "New API key is invalid — Tailscale API rejected it"
    exit 1
fi

DEVICE_COUNT=$(echo "$DEVICES_RESPONSE" | jq '.devices | length')
log "API key valid — tailnet has ${DEVICE_COUNT} devices"

# Get the new key's ID and expiry
KEYS_RESPONSE=$(curl -sf -u "${NEW_API_KEY}:" "${TAILSCALE_API}/tailnet/-/keys" 2>/dev/null)
# Find the API key that matches (extract ID from the key string: tskey-api-<ID>-<secret>)
NEW_KEY_ID=$(echo "$NEW_API_KEY" | sed -E 's/tskey-api-([^-]+)-.*/\1/')
NEW_KEY_EXPIRY=$(echo "$KEYS_RESPONSE" | jq -r ".keys[] | select(.id == \"${NEW_KEY_ID}\") | .expires[:10]")

if [[ -n "$NEW_KEY_EXPIRY" ]]; then
    log "New key ID: ${NEW_KEY_ID}, expires: ${NEW_KEY_EXPIRY}"
else
    warn "Could not find key details for ${NEW_KEY_ID} — continuing anyway"
fi

#===============================================================================
# Step 2: Get the old API key from the K8s secret
#===============================================================================
log "Reading old API key from ${SECRET_NAME}..."
OLD_API_KEY=$(kubectl get secret "$SECRET_NAME" -n "$SECRET_NS" -o jsonpath='{.data.tailscale-api-token}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
OLD_KEY_ID=$(kubectl get secret "$SECRET_NAME" -n "$SECRET_NS" -o jsonpath='{.data.tailscale-api-key-id}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [[ -n "$OLD_KEY_ID" ]]; then
    log "Old key ID: ${OLD_KEY_ID}"
else
    warn "No old key ID found in secret — skipping old key cleanup"
fi

#===============================================================================
# Step 3: Update the K8s secret
#===============================================================================
log "Updating ${SECRET_NAME} with new API key..."
kubectl patch secret "$SECRET_NAME" -n "$SECRET_NS" -p "{
    \"data\": {
        \"tailscale-api-token\": \"$(echo -n "$NEW_API_KEY" | base64)\",
        \"tailscale-api-key-id\": \"$(echo -n "$NEW_KEY_ID" | base64)\"
    }
}" > /dev/null

log "K8s secret updated"

#===============================================================================
# Step 4: Delete the old API key from Tailscale
#===============================================================================
if [[ -n "$OLD_KEY_ID" && "$OLD_KEY_ID" != "$NEW_KEY_ID" ]]; then
    log "Deleting old API key ${OLD_KEY_ID} from Tailscale..."
    if curl -sf -u "${NEW_API_KEY}:" -X DELETE "${TAILSCALE_API}/tailnet/-/keys/${OLD_KEY_ID}" 2>/dev/null; then
        log "Old key deleted"
    else
        warn "Could not delete old key ${OLD_KEY_ID} — it may already be expired"
    fi
else
    log "No old key to delete (same key or missing)"
fi

#===============================================================================
# Step 5: Create a fresh auth key for provisioning
#===============================================================================
log "Creating fresh provisioning auth key..."
AUTH_RESPONSE=$(curl -sf -u "${NEW_API_KEY}:" \
    -X POST "${TAILSCALE_API}/tailnet/-/keys" \
    -H "Content-Type: application/json" \
    -d '{
        "capabilities": {
            "devices": {
                "create": {
                    "reusable": true,
                    "ephemeral": false,
                    "preauthorized": true
                }
            }
        },
        "expirySeconds": 7776000,
        "description": "kube-world provisioning"
    }')

AUTH_KEY=$(echo "$AUTH_RESPONSE" | jq -r '.key // empty')
AUTH_KEY_ID=$(echo "$AUTH_RESPONSE" | jq -r '.id // empty')
AUTH_EXPIRY=$(echo "$AUTH_RESPONSE" | jq -r '.expires[:10] // empty')

if [[ -z "$AUTH_KEY" ]]; then
    error "Failed to create auth key"
    error "Response: $AUTH_RESPONSE"
    warn "API key rotation succeeded but auth key creation failed"
    warn "Auth key can be created later or manually"
    exit 1
fi

log "Auth key created: ${AUTH_KEY_ID} (expires ${AUTH_EXPIRY})"

# Also delete any old provisioning auth keys
log "Cleaning up old provisioning auth keys..."
OLD_AUTH_KEYS=$(echo "$KEYS_RESPONSE" | jq -r '.keys[] | select(.keyType == "auth" and .description == "kube-world provisioning") | .id')
for old_id in $OLD_AUTH_KEYS; do
    if [[ "$old_id" != "$AUTH_KEY_ID" ]]; then
        curl -sf -u "${NEW_API_KEY}:" -X DELETE "${TAILSCALE_API}/tailnet/-/keys/${old_id}" 2>/dev/null && \
            log "  Deleted old auth key: ${old_id}" || true
    fi
done

#===============================================================================
# Step 6: Store auth key in K8s secret
#===============================================================================
log "Storing auth key in ${SECRET_NAME}..."
kubectl patch secret "$SECRET_NAME" -n "$SECRET_NS" -p "{
    \"data\": {
        \"tailscale-auth-key\": \"$(echo -n "$AUTH_KEY" | base64)\",
        \"tailscale-auth-key-id\": \"$(echo -n "$AUTH_KEY_ID" | base64)\"
    }
}" > /dev/null

echo ""
log "=============================================="
log "  Tailscale API Key Rotation Complete"
log "=============================================="
log "  API key:  ${NEW_KEY_ID} (expires ${NEW_KEY_EXPIRY:-unknown})"
log "  Auth key: ${AUTH_KEY_ID} (expires ${AUTH_EXPIRY})"
log "  Secret:   ${SECRET_NS}/${SECRET_NAME}"
log "=============================================="
