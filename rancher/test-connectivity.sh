#!/usr/bin/env bash
#===============================================================================
# Rancher Connectivity Test Script
# Tests network connectivity from downstream cluster (RPi) to Rancher on Mac
#
# USAGE:
#   # Run from RPi:
#   ./test-connectivity.sh <mac-ip-or-hostname>
#
#   # Examples:
#   ./test-connectivity.sh 192.168.1.50
#   ./test-connectivity.sh rancher.192.168.1.50.nip.io
#
#===============================================================================
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[TEST]${NC} $*"; }
warn() { echo -e "${YELLOW}[TEST]${NC} $*"; }
error() { echo -e "${RED}[TEST]${NC} $*"; }
info() { echo -e "${BLUE}[TEST]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#===============================================================================
# Print usage
#===============================================================================
usage() {
    echo "Usage: $0 <rancher-host>"
    echo ""
    echo "Examples:"
    echo "  $0 192.168.1.50"
    echo "  $0 rancher.192.168.1.50.nip.io"
    echo ""
    echo "This script tests connectivity from this machine to the Rancher server."
    exit 1
}

#===============================================================================
# Test DNS resolution
#===============================================================================
test_dns() {
    local hostname="$1"

    info "Testing DNS resolution for: ${hostname}"

    # Skip if it's an IP address
    if [[ "$hostname" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "  ✓ Direct IP address (no DNS needed)"
        return 0
    fi

    # Test resolution
    local resolved_ip
    if resolved_ip=$(getent hosts "$hostname" 2>/dev/null | awk '{print $1}' | head -1); then
        if [[ -n "$resolved_ip" ]]; then
            log "  ✓ Resolved to: ${resolved_ip}"
            return 0
        fi
    fi

    # Try nslookup as fallback
    if command -v nslookup &>/dev/null; then
        if resolved_ip=$(nslookup "$hostname" 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1); then
            if [[ -n "$resolved_ip" ]]; then
                log "  ✓ Resolved to: ${resolved_ip}"
                return 0
            fi
        fi
    fi

    # Try host command
    if command -v host &>/dev/null; then
        if resolved_ip=$(host "$hostname" 2>/dev/null | grep "has address" | awk '{print $4}' | head -1); then
            if [[ -n "$resolved_ip" ]]; then
                log "  ✓ Resolved to: ${resolved_ip}"
                return 0
            fi
        fi
    fi

    error "  ✗ DNS resolution failed"
    error "    Ensure you can resolve ${hostname}"
    error "    For nip.io domains, check internet connectivity"
    return 1
}

#===============================================================================
# Test ICMP ping
#===============================================================================
test_ping() {
    local target="$1"

    info "Testing ICMP connectivity to: ${target}"

    # Extract IP if hostname contains it (e.g., nip.io)
    local ip_to_ping="$target"
    if [[ "$target" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
        ip_to_ping="${BASH_REMATCH[1]}"
    fi

    if ping -c 3 -W 2 "$ip_to_ping" &>/dev/null; then
        local latency
        latency=$(ping -c 1 -W 2 "$ip_to_ping" 2>/dev/null | grep "time=" | sed -E 's/.*time=([0-9.]+).*/\1/' || echo "?")
        log "  ✓ Host reachable (latency: ${latency}ms)"
        return 0
    else
        warn "  ⚠ Ping failed (ICMP may be blocked)"
        return 0  # Don't fail - ICMP might be blocked
    fi
}

#===============================================================================
# Test TCP port connectivity
#===============================================================================
test_port() {
    local host="$1"
    local port="$2"
    local description="$3"

    info "Testing TCP port ${port} (${description})"

    # Try nc (netcat)
    if command -v nc &>/dev/null; then
        if nc -z -w 3 "$host" "$port" 2>/dev/null; then
            log "  ✓ Port ${port} is open"
            return 0
        fi
    fi

    # Try /dev/tcp (bash built-in)
    if timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null; then
        log "  ✓ Port ${port} is open"
        return 0
    fi

    # Try curl as last resort
    if curl -s --connect-timeout 3 "http://${host}:${port}" &>/dev/null || \
       curl -s --connect-timeout 3 -k "https://${host}:${port}" &>/dev/null; then
        log "  ✓ Port ${port} is responding"
        return 0
    fi

    error "  ✗ Port ${port} is not reachable"
    error "    Check: Mac firewall, KIND port mapping, Docker networking"
    return 1
}

#===============================================================================
# Test HTTPS endpoint
#===============================================================================
test_https() {
    local host="$1"

    info "Testing HTTPS endpoint"

    # Test with certificate verification (will likely fail with self-signed)
    local response
    local http_code

    # First try without cert verification
    http_code=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://${host}/ping" 2>/dev/null || echo "000")

    if [[ "$http_code" == "200" ]]; then
        log "  ✓ Rancher API responding (HTTP 200)"

        # Check cert details
        local cert_info
        cert_info=$(echo | openssl s_client -connect "${host}:443" -servername "$host" 2>/dev/null | openssl x509 -noout -subject -issuer 2>/dev/null || echo "")
        if [[ -n "$cert_info" ]]; then
            info "  Certificate info:"
            echo "$cert_info" | sed 's/^/    /'
        fi
        return 0
    elif [[ "$http_code" == "000" ]]; then
        error "  ✗ Cannot establish HTTPS connection"
        return 1
    else
        warn "  ⚠ Rancher responded with HTTP ${http_code}"
        return 0
    fi
}

#===============================================================================
# Test Rancher specific endpoints
#===============================================================================
test_rancher_endpoints() {
    local host="$1"

    info "Testing Rancher-specific endpoints"

    # Test /ping endpoint
    local ping_response
    ping_response=$(curl -k -s --connect-timeout 5 "https://${host}/ping" 2>/dev/null || echo "")
    if [[ "$ping_response" == "pong" ]]; then
        log "  ✓ /ping endpoint: pong"
    else
        warn "  ⚠ /ping endpoint: ${ping_response:-no response}"
    fi

    # Test /v3 endpoint (API)
    local api_code
    api_code=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://${host}/v3" 2>/dev/null || echo "000")
    if [[ "$api_code" == "200" || "$api_code" == "401" ]]; then
        log "  ✓ /v3 API endpoint responding (HTTP ${api_code})"
    else
        warn "  ⚠ /v3 API endpoint: HTTP ${api_code}"
    fi

    # Test /v3/import (requires auth, expect 401)
    local import_code
    import_code=$(curl -k -s -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://${host}/v3/import" 2>/dev/null || echo "000")
    if [[ "$import_code" == "401" || "$import_code" == "403" ]]; then
        log "  ✓ /v3/import endpoint exists (auth required)"
    else
        warn "  ⚠ /v3/import endpoint: HTTP ${import_code}"
    fi
}

#===============================================================================
# Generate summary
#===============================================================================
generate_summary() {
    local host="$1"
    local all_passed="$2"

    echo ""
    echo "=============================================="
    if [[ "$all_passed" == "true" ]]; then
        echo -e "  ${GREEN}All connectivity tests passed!${NC}"
    else
        echo -e "  ${YELLOW}Some tests failed${NC}"
    fi
    echo "=============================================="
    echo ""
    echo "  Target: ${host}"
    echo ""
    if [[ "$all_passed" == "true" ]]; then
        echo "  Rancher should be accessible from this machine."
        echo "  You can now import this cluster:"
        echo ""
        echo "    ./rancher/import-cluster.sh <import-url-from-rancher-ui>"
        echo ""
    else
        echo "  Troubleshooting steps:"
        echo ""
        echo "  1. On Mac, verify KIND ports are exposed:"
        echo "     docker port kube-world-control-plane"
        echo ""
        echo "  2. Check Mac firewall (System Preferences > Security > Firewall)"
        echo ""
        echo "  3. Verify Rancher is running:"
        echo "     kubectl -n cattle-system get pods"
        echo ""
        echo "  4. Check ingress controller:"
        echo "     kubectl -n ingress-nginx get pods"
        echo ""
        echo "  5. Test from Mac:"
        echo "     curl -k https://localhost/ping"
        echo ""
    fi
}

#===============================================================================
# Main
#===============================================================================
main() {
    if [[ $# -lt 1 ]]; then
        usage
    fi

    local target="$1"
    local all_passed=true

    echo ""
    echo "=============================================="
    echo "  Rancher Connectivity Test"
    echo "=============================================="
    echo ""
    echo "  Testing from: $(hostname)"
    echo "  Target: ${target}"
    echo ""

    # Run tests
    if ! test_dns "$target"; then
        all_passed=false
    fi

    test_ping "$target"  # Don't fail on ping

    if ! test_port "$target" 80 "HTTP"; then
        all_passed=false
    fi

    if ! test_port "$target" 443 "HTTPS"; then
        all_passed=false
    fi

    if ! test_https "$target"; then
        all_passed=false
    fi

    test_rancher_endpoints "$target"

    generate_summary "$target" "$all_passed"

    if [[ "$all_passed" == "true" ]]; then
        exit 0
    else
        exit 1
    fi
}

main "$@"
