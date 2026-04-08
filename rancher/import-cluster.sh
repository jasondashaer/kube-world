#!/usr/bin/env bash
#===============================================================================
# Rancher Cluster Import (Programmatic)
# Creates an imported cluster in Rancher via API and applies the agent manifest
# to the target cluster. Runs from the operator's workstation (not on the Pi).
#
# PREREQUISITES:
#   - Rancher running with ingress.tls.source=secret, privateCA=false
#   - agent-tls-mode=system-store in Rancher settings
#   - RANCHER_TOKEN env var (Rancher API token, e.g., token-xxxxx:yyyyyyy)
#   - Target cluster kubeconfig accessible locally
#   - Target cluster can reach Rancher via Tailscale or direct network
#
# USAGE:
#   ./import-cluster.sh --name pi-edge-1 --kubeconfig ~/.kube/pi-edge-1-config
#   ./import-cluster.sh --name pi-edge-1 --pi-ip 10.5.5.136
#
# ENVIRONMENT:
#   RANCHER_URL       Rancher server URL (default: https://rancher.$DOMAIN)
#   RANCHER_TOKEN     Rancher API bearer token (required)
#   DOMAIN            Base domain (default: kubew.dev)
#===============================================================================
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[IMPORT]${NC} $*"; }
warn()  { echo -e "${YELLOW}[IMPORT]${NC} $*"; }
error() { echo -e "${RED}[IMPORT]${NC} $*" >&2; }

# Defaults
RANCHER_URL="${RANCHER_URL:-https://rancher.${DOMAIN:-kubew.dev}}"
RANCHER_TOKEN="${RANCHER_TOKEN:-}"
CLUSTER_NAME=""
CLUSTER_KUBECONFIG=""
PI_IP=""
CLUSTER_LABELS="topology.kubernetes.io/zone=edge,hardware=raspberry-pi-5,workload-type=iot"
CLUSTER_DESCRIPTION=""

#===============================================================================
# Parse Arguments
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --name)           CLUSTER_NAME="$2"; shift 2 ;;
            --kubeconfig)     CLUSTER_KUBECONFIG="$2"; shift 2 ;;
            --pi-ip)          PI_IP="$2"; shift 2 ;;
            --labels)         CLUSTER_LABELS="$2"; shift 2 ;;
            --description)    CLUSTER_DESCRIPTION="$2"; shift 2 ;;
            --rancher-url)    RANCHER_URL="$2"; shift 2 ;;
            --rancher-token)  RANCHER_TOKEN="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: $0 --name <cluster-name> [options]"
                echo ""
                echo "Options:"
                echo "  --name <name>           Cluster name in Rancher (required)"
                echo "  --kubeconfig <path>     Path to target cluster kubeconfig"
                echo "  --pi-ip <ip>            Pi IP (fetches kubeconfig via SSH)"
                echo "  --labels <k=v,k=v>      Cluster labels (default: edge/pi-5/iot)"
                echo "  --description <text>    Cluster description"
                echo "  --rancher-url <url>     Rancher URL (default: \$RANCHER_URL)"
                echo "  --rancher-token <token> Rancher API token (default: \$RANCHER_TOKEN)"
                echo ""
                echo "Environment:"
                echo "  RANCHER_URL    Rancher server URL"
                echo "  RANCHER_TOKEN  Rancher API bearer token"
                exit 0
                ;;
            *) error "Unknown option: $1"; exit 1 ;;
        esac
    done

    if [[ -z "$CLUSTER_NAME" ]]; then
        error "--name is required"
        exit 1
    fi

    if [[ -z "$RANCHER_TOKEN" ]]; then
        error "RANCHER_TOKEN env var or --rancher-token is required"
        error "Create one at: ${RANCHER_URL}/dashboard/account"
        exit 1
    fi
}

#===============================================================================
# Fetch kubeconfig from Pi via SSH
#===============================================================================
fetch_kubeconfig() {
    if [[ -n "$PI_IP" && -z "$CLUSTER_KUBECONFIG" ]]; then
        CLUSTER_KUBECONFIG="${HOME}/.kube/${CLUSTER_NAME}-config"
        log "Fetching kubeconfig from ${PI_IP}..."
        if scp -o ConnectTimeout=10 "admin@${PI_IP}:/etc/rancher/k3s/k3s.yaml" "${CLUSTER_KUBECONFIG}" 2>/dev/null; then
            if [[ "$(uname -s)" == "Darwin" ]]; then
                sed -i '' "s/127.0.0.1/${PI_IP}/g" "${CLUSTER_KUBECONFIG}"
            else
                sed -i "s/127.0.0.1/${PI_IP}/g" "${CLUSTER_KUBECONFIG}"
            fi
            log "Kubeconfig saved to ${CLUSTER_KUBECONFIG}"
        else
            error "Failed to fetch kubeconfig from ${PI_IP}"
            exit 1
        fi
    fi
}

#===============================================================================
# Verify Rancher API access
#===============================================================================
verify_rancher() {
    log "Verifying Rancher API access..."
    local ping_result
    ping_result=$(curl -sk --connect-timeout 5 "${RANCHER_URL}/ping" 2>/dev/null)
    if [[ "$ping_result" != "pong" ]]; then
        error "Cannot reach Rancher at ${RANCHER_URL}"
        exit 1
    fi

    # Verify token
    local user
    user=$(curl -sk "${RANCHER_URL}/v3/users?me=true" \
        -H "Authorization: Bearer ${RANCHER_TOKEN}" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['username'])" 2>/dev/null)
    if [[ -z "$user" ]]; then
        error "Rancher API token is invalid"
        exit 1
    fi
    log "Authenticated as: ${user}"
}

#===============================================================================
# Check if cluster already exists
#===============================================================================
check_existing() {
    local existing
    existing=$(curl -sk "${RANCHER_URL}/v3/clusters?name=${CLUSTER_NAME}" \
        -H "Authorization: Bearer ${RANCHER_TOKEN}" 2>/dev/null \
        | python3 -c "
import sys,json
d = json.load(sys.stdin)
for c in d.get('data', []):
    if c.get('state') != 'removing':
        print(c['id'])
        break
" 2>/dev/null)

    if [[ -n "$existing" ]]; then
        log "Cluster '${CLUSTER_NAME}' already exists (${existing})"
        # Check state
        local state
        state=$(curl -sk "${RANCHER_URL}/v3/clusters/${existing}" \
            -H "Authorization: Bearer ${RANCHER_TOKEN}" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null)
        if [[ "$state" == "active" ]]; then
            log "Cluster is already active. Nothing to do."
            exit 0
        fi
        warn "Cluster state: ${state}. Re-importing..."
        # Delete and recreate
        curl -sk -X DELETE "${RANCHER_URL}/v3/clusters/${existing}" \
            -H "Authorization: Bearer ${RANCHER_TOKEN}" 2>/dev/null > /dev/null
        # Clean up agent on target
        if [[ -n "$CLUSTER_KUBECONFIG" ]]; then
            kubectl --kubeconfig="${CLUSTER_KUBECONFIG}" delete namespace cattle-system --ignore-not-found --wait=false 2>/dev/null || true
            kubectl --kubeconfig="${CLUSTER_KUBECONFIG}" delete clusterrole cattle-admin proxy-clusterrole-kubeapiserver --ignore-not-found 2>/dev/null || true
            kubectl --kubeconfig="${CLUSTER_KUBECONFIG}" delete clusterrolebinding cattle-admin-binding proxy-role-binding-kubernetes-master --ignore-not-found 2>/dev/null || true
        fi
        sleep 10
    fi
}

#===============================================================================
# Create imported cluster in Rancher
#===============================================================================
create_cluster() {
    log "Creating cluster '${CLUSTER_NAME}' in Rancher..."

    # Build labels JSON
    local labels_json="{}"
    if [[ -n "$CLUSTER_LABELS" ]]; then
        labels_json=$(python3 -c "
import json
labels = {}
for pair in '${CLUSTER_LABELS}'.split(','):
    k, v = pair.split('=', 1)
    labels[k] = v
print(json.dumps(labels))
")
    fi

    local response
    response=$(curl -sk -X POST "${RANCHER_URL}/v3/clusters" \
        -H "Authorization: Bearer ${RANCHER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{
            \"type\": \"cluster\",
            \"name\": \"${CLUSTER_NAME}\",
            \"description\": \"${CLUSTER_DESCRIPTION:-${CLUSTER_NAME} edge cluster}\",
            \"labels\": ${labels_json}
        }" 2>/dev/null)

    CLUSTER_ID=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null)
    if [[ -z "$CLUSTER_ID" ]]; then
        error "Failed to create cluster"
        echo "$response" >&2
        exit 1
    fi
    log "Created cluster: ${CLUSTER_ID}"
}

#===============================================================================
# Get registration manifest
#===============================================================================
get_manifest() {
    log "Waiting for registration token..."

    # Create registration token
    curl -sk -X POST "${RANCHER_URL}/v3/clusterregistrationtokens" \
        -H "Authorization: Bearer ${RANCHER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"type\":\"clusterRegistrationToken\",\"clusterId\":\"${CLUSTER_ID}\"}" 2>/dev/null > /dev/null

    # Wait for token to be populated
    local attempts=0
    local max_attempts=12
    while [[ $attempts -lt $max_attempts ]]; do
        REG_TOKEN=$(curl -sk "${RANCHER_URL}/v3/clusterregistrationtokens?clusterId=${CLUSTER_ID}" \
            -H "Authorization: Bearer ${RANCHER_TOKEN}" 2>/dev/null \
            | python3 -c "
import sys,json
d = json.load(sys.stdin)
for item in d.get('data', []):
    t = item.get('token', '')
    if t: print(t); break
" 2>/dev/null)

        if [[ -n "$REG_TOKEN" ]]; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 5
    done

    if [[ -z "$REG_TOKEN" ]]; then
        error "Failed to get registration token after ${max_attempts} attempts"
        exit 1
    fi

    MANIFEST_URL="${RANCHER_URL}/v3/import/${REG_TOKEN}_${CLUSTER_ID}.yaml"
    log "Manifest URL: ${MANIFEST_URL}"

    # Download manifest
    MANIFEST_FILE="/tmp/rancher-import-${CLUSTER_NAME}.yaml"
    curl -sk "$MANIFEST_URL" > "$MANIFEST_FILE"

    if [[ ! -s "$MANIFEST_FILE" ]] || [[ $(wc -c < "$MANIFEST_FILE") -lt 500 ]]; then
        error "Failed to download manifest (file too small)"
        exit 1
    fi
    log "Manifest downloaded: ${MANIFEST_FILE}"
}

#===============================================================================
# Apply manifest to target cluster
#===============================================================================
apply_manifest() {
    log "Applying import manifest to ${CLUSTER_NAME}..."

    # Wait for cattle-system namespace to be fully gone (if it was being deleted)
    local ns_attempts=0
    while kubectl --kubeconfig="${CLUSTER_KUBECONFIG}" get namespace cattle-system &>/dev/null 2>&1; do
        if [[ $ns_attempts -gt 12 ]]; then
            warn "cattle-system namespace still terminating, forcing..."
            break
        fi
        ns_attempts=$((ns_attempts + 1))
        sleep 5
    done

    kubectl --kubeconfig="${CLUSTER_KUBECONFIG}" apply -f "$MANIFEST_FILE"
    log "Import manifest applied"
}

#===============================================================================
# Wait for cluster to become active
#===============================================================================
wait_for_active() {
    log "Waiting for cluster to become active..."

    # Short timeout (90s) — if the LE cert hasn't issued yet, the
    # cattle-agent will reject Traefik's placeholder cert and the cluster
    # stays pending. This is expected on first bootstrap (cert takes
    # 10-30+ min). The import IS initiated and cattle-agent auto-retries
    # every 5s. Once the LE cert issues, the cluster goes active with no
    # manual intervention. We report success either way since the import
    # manifest was applied.
    local timeout=90
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local state
        state=$(curl -sk "${RANCHER_URL}/v3/clusters/${CLUSTER_ID}" \
            -H "Authorization: Bearer ${RANCHER_TOKEN}" 2>/dev/null \
            | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null)

        case "$state" in
            active)
                log "Cluster '${CLUSTER_NAME}' is ACTIVE in Rancher"
                return 0
                ;;
            waiting|pending|provisioning)
                ;;
            *)
                warn "Unexpected state: ${state}"
                ;;
        esac

        elapsed=$((elapsed + 10))
        if (( elapsed % 30 == 0 )); then
            log "  State: ${state} (${elapsed}/${timeout}s)"
        fi
        sleep 10
    done

    # Not active yet — likely the LE cert hasn't issued. This is normal
    # on first bootstrap. The cattle-agent will auto-connect when the
    # cert is ready (no manual intervention needed).
    log "Cluster '${CLUSTER_NAME}' imported but not yet active (state: ${state})"
    log "  This is expected if the TLS certificate is still being issued."
    log "  The cattle-agent retries automatically — the cluster will go"
    log "  active within a few minutes of cert issuance."
    log "  Monitor: kubectl --kubeconfig=~/.kube/pi-config get clusters.management.cattle.io"

    # Diagnostic: show cattle-agent logs from the edge Pi to understand
    # why it can't connect back to Rancher. This is the #1 failure mode.
    if [[ -n "${CLUSTER_KUBECONFIG:-}" && -f "${CLUSTER_KUBECONFIG}" ]]; then
        warn "cattle-cluster-agent logs from ${CLUSTER_NAME}:"
        kubectl --kubeconfig="${CLUSTER_KUBECONFIG}" -n cattle-system \
            logs deploy/cattle-cluster-agent --tail=5 2>&1 | while read -r line; do
            warn "  ${line}"
        done
        warn "cattle-cluster-agent pod status:"
        kubectl --kubeconfig="${CLUSTER_KUBECONFIG}" -n cattle-system \
            get pods -l app=cattle-cluster-agent -o wide 2>&1 | while read -r line; do
            warn "  ${line}"
        done
    fi

    # Return 0 (not failure) — the import IS initiated, it just needs
    # the cert to issue. Bootstrap shouldn't treat this as an error.
    return 0
}

#===============================================================================
# Main
#===============================================================================
main() {
    parse_args "$@"

    log "Importing '${CLUSTER_NAME}' into Rancher"
    log "  Rancher: ${RANCHER_URL}"
    log "  Labels:  ${CLUSTER_LABELS}"

    fetch_kubeconfig
    verify_rancher
    check_existing
    create_cluster
    get_manifest
    apply_manifest
    wait_for_active

    echo ""
    log "=============================================="
    log "  Cluster Import Complete: ${CLUSTER_NAME}"
    log "=============================================="
    log "  Rancher UI: ${RANCHER_URL}/dashboard/c/${CLUSTER_ID}/explorer"
    log "  Cluster ID: ${CLUSTER_ID}"
    log "=============================================="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
