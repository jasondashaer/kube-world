#!/usr/bin/env bash
#===============================================================================
# Pi Cluster Import to Rancher
# Imports the Pi K3s cluster into Rancher running on Mac
#
# USAGE:
#   # With auto-discovery of Rancher
#   ./join-cluster.sh
#
#   # With explicit Rancher host
#   ./join-cluster.sh <rancher-hostname-or-ip>
#
#   # With full import URL from Rancher UI
#   ./join-cluster.sh <full-import-url>
#
# PREREQUISITES:
#   - K3s installed and running on this Pi
#   - kubectl configured (~/.kube/config)
#   - Network connectivity to Mac running Rancher
#
#===============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[JOIN]${NC} $*"; }
warn() { echo -e "${YELLOW}[JOIN]${NC} $*"; }
error() { echo -e "${RED}[JOIN]${NC} $*" >&2; }
info() { echo -e "${BLUE}[JOIN]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/.."

#===============================================================================
# Verify K3s is running
#===============================================================================
verify_k3s() {
    log "Verifying K3s cluster is running..."

    if ! command -v kubectl &>/dev/null; then
        error "kubectl not found. Is K3s installed?"
        return 1
    fi

    if ! kubectl get nodes &>/dev/null; then
        error "Cannot connect to K3s cluster."
        error "Check if K3s is running: sudo systemctl status k3s"
        return 1
    fi

    local node_status
    node_status=$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}')
    if [[ "$node_status" != "True" ]]; then
        warn "K3s node is not Ready. Current status:"
        kubectl get nodes
        warn "Continuing anyway..."
    else
        log "✓ K3s cluster is ready"
    fi
}

#===============================================================================
# Discover Rancher on the network
#===============================================================================
discover_rancher() {
    log "Attempting to discover Rancher server on the network..."

    # Check if rancher-info exists in repo
    local info_file="${REPO_ROOT}/rancher/.rancher-info"
    if [[ -f "$info_file" ]]; then
        # shellcheck source=/dev/null
        source "$info_file"
        if [[ -n "${RANCHER_HOSTNAME:-}" ]]; then
            log "Found Rancher info: ${RANCHER_HOSTNAME}"
            echo "$RANCHER_HOSTNAME"
            return 0
        fi
    fi

    # Try to find Mac on the network via mDNS/Bonjour
    log "Checking for mDNS/Bonjour hosts..."
    if command -v avahi-browse &>/dev/null; then
        # Look for workstation services
        local mac_host
        mac_host=$(avahi-browse -trp _workstation._tcp 2>/dev/null | grep -i "macbook\|mac-" | head -1 | cut -d';' -f7 || true)
        if [[ -n "$mac_host" ]]; then
            log "Found Mac via mDNS: ${mac_host}"
            # Try common Rancher ports
            if curl -k -s --connect-timeout 2 "https://${mac_host}/ping" &>/dev/null; then
                echo "$mac_host"
                return 0
            fi
        fi
    fi

    # Scan common network ranges for Rancher
    log "Scanning local network for Rancher..."
    local gateway
    gateway=$(ip route | grep default | awk '{print $3}' || true)
    if [[ -n "$gateway" ]]; then
        # Get network prefix
        local network_prefix
        network_prefix=$(echo "$gateway" | sed 's/\.[0-9]*$//')

        # Quick scan common Mac IPs
        for i in 1 2 50 51 52 100 101 150 200; do
            local test_ip="${network_prefix}.${i}"
            if curl -k -s --connect-timeout 1 "https://${test_ip}/ping" 2>/dev/null | grep -q "pong"; then
                log "Found Rancher at: ${test_ip}"
                echo "${test_ip}"
                return 0
            fi
        done
    fi

    warn "Could not auto-discover Rancher server"
    return 1
}

#===============================================================================
# Test connectivity to Rancher
#===============================================================================
test_connectivity() {
    local rancher_host="$1"

    log "Testing connectivity to Rancher at: ${rancher_host}"

    # DNS/IP resolution
    if [[ ! "$rancher_host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if ! getent hosts "$rancher_host" &>/dev/null && ! host "$rancher_host" &>/dev/null 2>&1; then
            error "Cannot resolve hostname: ${rancher_host}"
            return 1
        fi
    fi

    # HTTPS test
    local http_code
    http_code=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://${rancher_host}/ping" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        log "✓ Rancher is accessible"
        return 0
    elif [[ "$http_code" == "000" ]]; then
        error "Cannot connect to Rancher"
        error ""
        error "Possible causes:"
        error "  1. Mac firewall blocking ports 80/443"
        error "  2. KIND ports not exposed on 0.0.0.0"
        error "  3. Wrong IP address"
        error ""
        error "On Mac, verify:"
        error "  docker port kube-world-control-plane"
        error "  curl -k https://localhost/ping"
        return 1
    else
        warn "Rancher responded with HTTP ${http_code}"
        return 0
    fi
}

#===============================================================================
# Apply import manifest
#===============================================================================
apply_import() {
    local import_url="$1"

    log "Fetching import manifest from Rancher..."

    # Fetch manifest with insecure flag (self-signed certs)
    local manifest
    if ! manifest=$(curl -k -sfL "$import_url" 2>&1); then
        error "Failed to fetch import manifest"
        error "Error: ${manifest}"
        error ""
        error "The import URL may have expired. Generate a new one in Rancher UI:"
        error "  Cluster Management > Import Existing > Copy the command"
        return 1
    fi

    # Validate YAML
    if ! echo "$manifest" | head -1 | grep -qE "^apiVersion|^---|^kind"; then
        error "Invalid manifest received (not valid YAML)"
        return 1
    fi

    log "Applying import manifest..."
    if ! echo "$manifest" | kubectl apply -f -; then
        error "Failed to apply import manifest"
        return 1
    fi

    log "✓ Import manifest applied successfully"
}

#===============================================================================
# Wait for registration
#===============================================================================
wait_for_registration() {
    log "Waiting for cluster agent to register..."

    local timeout=120
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        # Check for cattle-cluster-agent
        if kubectl -n cattle-system get pods -l app=cattle-cluster-agent --no-headers 2>/dev/null | grep -q "Running"; then
            log "✓ Cluster agent is running"

            # Show agent status
            kubectl -n cattle-system get pods

            echo ""
            log "=============================================="
            log "  Cluster Import Complete!"
            log "=============================================="
            log ""
            log "  Check Rancher UI for cluster status."
            log "  It may take a few minutes to show as 'Active'."
            log ""
            log "  Monitor agent logs:"
            log "    kubectl -n cattle-system logs -l app=cattle-cluster-agent -f"
            log ""
            return 0
        fi

        info "Waiting for agent... (${elapsed}/${timeout}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    warn "Cluster agent not running after ${timeout}s"
    warn "Check Rancher UI and agent logs for issues"
    kubectl -n cattle-system get pods 2>/dev/null || true
    return 1
}

#===============================================================================
# Interactive import
#===============================================================================
interactive_import() {
    local rancher_host="$1"

    echo ""
    log "=============================================="
    log "  Import This Cluster to Rancher"
    log "=============================================="
    log ""
    log "  Rancher URL: https://${rancher_host}"
    log ""
    log "  Steps:"
    log "    1. Open the Rancher UI in your browser"
    log "    2. Go to: Cluster Management > Import Existing"
    log "    3. Select 'Generic' and give it a name"
    log "    4. Copy the registration URL"
    log ""
    read -rp "  Paste the import URL here: " import_url

    if [[ -z "$import_url" ]]; then
        error "No URL provided"
        return 1
    fi

    apply_import "$import_url"
    wait_for_registration
}

#===============================================================================
# Main
#===============================================================================
main() {
    echo ""
    log "Pi Cluster Import to Rancher"
    log "=============================================="

    # Verify K3s is running
    verify_k3s

    local rancher_host=""
    local import_url=""

    # Parse arguments
    if [[ $# -ge 1 ]]; then
        local arg="$1"
        if [[ "$arg" =~ ^https?:// ]]; then
            # Full import URL provided
            import_url="$arg"
            rancher_host=$(echo "$arg" | sed -E 's|https?://([^/]+).*|\1|')
        else
            # Hostname/IP provided
            rancher_host="$arg"
        fi
    else
        # Try auto-discovery
        rancher_host=$(discover_rancher) || true
    fi

    if [[ -z "$rancher_host" ]]; then
        error "Could not determine Rancher server address."
        error ""
        error "Usage:"
        error "  $0 <rancher-host>"
        error "  $0 <full-import-url>"
        error ""
        error "Example:"
        error "  $0 rancher.192.168.1.50.nip.io"
        error "  $0 https://rancher.192.168.1.50.nip.io/v3/import/xxxx.yaml"
        exit 1
    fi

    # Test connectivity
    if ! test_connectivity "$rancher_host"; then
        exit 1
    fi

    # If we have full URL, apply directly
    if [[ -n "$import_url" ]]; then
        apply_import "$import_url"
        wait_for_registration
    else
        # Interactive mode
        interactive_import "$rancher_host"
    fi
}

main "$@"
