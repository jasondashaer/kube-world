#!/usr/bin/env bash
#===============================================================================
# Rancher Cluster Import Helper
# Imports a downstream cluster (e.g., RPi K3s) into Rancher management
#
# USAGE:
#   # From RPi or any downstream cluster:
#   ./import-cluster.sh <rancher-import-url>
#
#   # Or specify Rancher host directly:
#   RANCHER_HOST=rancher.192.168.1.50.nip.io ./import-cluster.sh
#
# PREREQUISITES:
#   - kubectl configured with access to the cluster being imported
#   - Network connectivity to Rancher server
#
#===============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[IMPORT]${NC} $*"; }
warn() { echo -e "${YELLOW}[IMPORT]${NC} $*"; }
error() { echo -e "${RED}[IMPORT]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#===============================================================================
# Load Rancher info if available
#===============================================================================
load_rancher_info() {
    local info_file="${SCRIPT_DIR}/.rancher-info"
    if [[ -f "$info_file" ]]; then
        log "Loading Rancher configuration from ${info_file}"
        # shellcheck source=/dev/null
        source "$info_file"
    fi
}

#===============================================================================
# Test connectivity to Rancher
#===============================================================================
test_rancher_connectivity() {
    local rancher_host="$1"

    log "Testing connectivity to ${rancher_host}..."

    # Extract IP from hostname for ping test
    local ip_addr
    if [[ "$rancher_host" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        ip_addr="${BASH_REMATCH[1]}"
        log "  Pinging ${ip_addr}..."
        if ping -c 1 -W 2 "$ip_addr" &>/dev/null; then
            log "  ✓ Host is reachable"
        else
            warn "  ✗ Ping failed - host may be blocking ICMP or unreachable"
        fi
    fi

    # Test HTTPS connectivity
    log "  Testing HTTPS connectivity..."
    local http_code
    http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${rancher_host}/ping" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        log "  ✓ Rancher is responding (HTTP ${http_code})"
        return 0
    elif [[ "$http_code" == "000" ]]; then
        error "  ✗ Cannot connect to Rancher (connection refused or timeout)"
        error ""
        error "  Troubleshooting:"
        error "    1. Verify Rancher is running: kubectl -n cattle-system get pods"
        error "    2. Check Mac firewall allows ports 80, 443"
        error "    3. Verify RPi can reach Mac: ping <mac-ip>"
        error "    4. Check KIND ports: docker port kube-world-control-plane"
        return 1
    else
        warn "  ⚠ Rancher responded with HTTP ${http_code}"
        return 0
    fi
}

#===============================================================================
# Fetch and apply import manifest
#===============================================================================
import_cluster() {
    local import_url="$1"

    log "Importing cluster from: ${import_url}"

    # Determine if we need --insecure flag
    local curl_opts="-sfL"
    if [[ "${RANCHER_INSECURE:-true}" == "true" ]]; then
        curl_opts="-k -sfL"
        log "Using insecure mode (self-signed certificates)"
    fi

    # Fetch the import manifest
    log "Fetching import manifest..."
    local manifest
    if ! manifest=$(curl $curl_opts "$import_url" 2>&1); then
        error "Failed to fetch import manifest from Rancher"
        error "Response: ${manifest}"
        error ""
        error "Common causes:"
        error "  - Import URL has expired (regenerate in Rancher UI)"
        error "  - Rancher hostname not resolvable from this machine"
        error "  - Certificate issues (try RANCHER_INSECURE=true)"
        return 1
    fi

    # Verify we got valid YAML
    if ! echo "$manifest" | head -1 | grep -q "^apiVersion\|^---\|^kind"; then
        error "Received invalid manifest (not YAML)"
        error "Content preview: $(echo "$manifest" | head -5)"
        return 1
    fi

    log "Manifest fetched successfully ($(echo "$manifest" | wc -l | tr -d ' ') lines)"

    # Apply to cluster
    log "Applying import manifest to cluster..."
    if echo "$manifest" | kubectl apply -f -; then
        log "✓ Import manifest applied successfully!"
    else
        error "Failed to apply import manifest"
        return 1
    fi

    # Wait for cattle-cluster-agent
    log "Waiting for Rancher agent to start..."
    sleep 5

    local agent_ns="cattle-system"
    if kubectl get namespace cattle-system &>/dev/null; then
        log "Checking cattle-system namespace..."
        kubectl -n cattle-system get pods 2>/dev/null || true
    fi

    echo ""
    log "=============================================="
    log "  Cluster Import Initiated!"
    log "=============================================="
    log ""
    log "  The cluster agent is being deployed."
    log "  Check Rancher UI for cluster status."
    log ""
    log "  Monitor agent status:"
    log "    kubectl -n cattle-system get pods -w"
    log ""
    log "  View agent logs:"
    log "    kubectl -n cattle-system logs -l app=cattle-cluster-agent -f"
    log ""
}

#===============================================================================
# Interactive mode - get import URL from Rancher API
#===============================================================================
interactive_import() {
    local rancher_host="${RANCHER_HOST:-${RANCHER_HOSTNAME:-}}"

    if [[ -z "$rancher_host" ]]; then
        error "RANCHER_HOST not set. Please provide the Rancher hostname."
        error ""
        error "Usage:"
        error "  RANCHER_HOST=rancher.192.168.1.50.nip.io $0"
        error ""
        error "Or provide the full import URL:"
        error "  $0 https://rancher.example.com/v3/import/xxxx.yaml"
        return 1
    fi

    if ! test_rancher_connectivity "$rancher_host"; then
        return 1
    fi

    echo ""
    log "To import this cluster:"
    log ""
    log "  1. Open Rancher: https://${rancher_host}"
    log "  2. Go to: Cluster Management > Import Existing"
    log "  3. Choose 'Generic', name your cluster"
    log "  4. Copy the import URL and run:"
    log ""
    log "     $0 <paste-import-url-here>"
    log ""
}

#===============================================================================
# Main
#===============================================================================
main() {
    load_rancher_info

    if [[ $# -ge 1 ]]; then
        local import_url="$1"

        # Validate URL format
        if [[ ! "$import_url" =~ ^https?:// ]]; then
            error "Invalid import URL. Must start with https://"
            exit 1
        fi

        # Extract hostname for connectivity test
        local rancher_host
        rancher_host=$(echo "$import_url" | sed -E 's|https?://([^/]+).*|\1|')

        if test_rancher_connectivity "$rancher_host"; then
            import_cluster "$import_url"
        else
            exit 1
        fi
    else
        interactive_import
    fi
}

main "$@"
