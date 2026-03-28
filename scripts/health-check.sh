#!/usr/bin/env bash
#===============================================================================
# Kube-World Health Check Script
#
# Comprehensive diagnostics for the entire kube-world infrastructure:
#   - Mac (KIND/Rancher) cluster
#   - Pi (K3s) cluster
#   - Network connectivity between clusters
#   - All core components
#
# USAGE:
#   ./scripts/health-check.sh              # Run all checks
#   ./scripts/health-check.sh --mac-only   # Mac cluster only
#   ./scripts/health-check.sh --pi-only    # Pi cluster only
#   ./scripts/health-check.sh --network    # Network connectivity only
#   ./scripts/health-check.sh --fix        # Attempt auto-fixes
#
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Counters
PASSED=0
FAILED=0
WARNINGS=0

# Options
MAC_ONLY=false
PI_ONLY=false
NETWORK_ONLY=false
AUTO_FIX=false

#===============================================================================
# Output Functions
#===============================================================================
pass() {
    echo -e "${GREEN}✓${NC} $*"
    ((PASSED++))
}
fail() {
    echo -e "${RED}✗${NC} $*"
    ((FAILED++))
}
warn() {
    echo -e "${YELLOW}⚠${NC} $*"
    ((WARNINGS++))
}
info() {
    echo -e "${BLUE}ℹ${NC} $*"
}
header() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════════════════${NC}"
}
section() {
    echo ""
    echo -e "${BOLD}▶ $*${NC}"
    echo ""
}

#===============================================================================
# Parse Arguments
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --mac-only) MAC_ONLY=true; shift ;;
            --pi-only) PI_ONLY=true; shift ;;
            --network) NETWORK_ONLY=true; shift ;;
            --fix) AUTO_FIX=true; shift ;;
            -h|--help)
                echo "Usage: $0 [--mac-only|--pi-only|--network] [--fix]"
                exit 0
                ;;
            *) echo "Unknown option: $1"; exit 1 ;;
        esac
    done
}

#===============================================================================
# Mac Cluster Checks
#===============================================================================
check_mac_cluster() {
    header "Mac Cluster Health Check"

    section "Docker"
    if docker info &>/dev/null; then
        pass "Docker is running"
        local docker_memory
        docker_memory=$(docker system info 2>/dev/null | grep "Total Memory" | awk '{print $3}')
        if [[ -n "$docker_memory" ]]; then
            info "Docker memory: ${docker_memory}"
            local mem_gb
            mem_gb=$(echo "$docker_memory" | grep -oE '[0-9]+' | head -1)
            if [[ "$mem_gb" -lt 10 ]]; then
                warn "Docker has less than 10GB RAM (may cause Rancher issues)"
            fi
        fi
    else
        fail "Docker is not running"
        [[ "$AUTO_FIX" == "true" ]] && { info "Starting Docker..."; open -a Docker; sleep 10; }
    fi

    section "KIND Cluster"
    if kind get clusters 2>/dev/null | grep -q "kube-world"; then
        pass "KIND cluster 'kube-world' exists"

        # Check node status
        local node_ready
        node_ready=$(kubectl --context kind-kube-world get nodes -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if echo "$node_ready" | grep -q "True"; then
            pass "KIND nodes are Ready"
        else
            fail "KIND nodes are not Ready"
            kubectl --context kind-kube-world get nodes 2>/dev/null || true
        fi

        # Check port mappings
        local port_80
        port_80=$(docker port kube-world-control-plane 80 2>/dev/null || echo "")
        if [[ "$port_80" == *"0.0.0.0:80"* ]]; then
            pass "Port 80 exposed on all interfaces"
        else
            warn "Port 80 not exposed on 0.0.0.0 (Pi may not be able to connect)"
        fi

        local port_443
        port_443=$(docker port kube-world-control-plane 443 2>/dev/null || echo "")
        if [[ "$port_443" == *"0.0.0.0:443"* ]]; then
            pass "Port 443 exposed on all interfaces"
        else
            warn "Port 443 not exposed on 0.0.0.0 (Pi may not be able to connect)"
        fi
    else
        fail "KIND cluster 'kube-world' does not exist"
        info "Create with: ./bootstrap.sh --platform mac"
    fi

    section "Ingress Controller"
    local ingress_pods
    ingress_pods=$(kubectl --context kind-kube-world -n ingress-nginx get pods -l app.kubernetes.io/name=ingress-nginx -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
    if [[ "$ingress_pods" == *"Running"* ]]; then
        pass "Ingress controller is running"
    else
        fail "Ingress controller is not running"
        [[ "$AUTO_FIX" == "true" ]] && { info "Installing ingress controller..."; helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace -f /tmp/ingress-nginx-values.yaml 2>/dev/null || true; }
    fi

    section "cert-manager"
    local certmgr_pods
    certmgr_pods=$(kubectl --context kind-kube-world -n cert-manager get pods -l app=cert-manager -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
    if [[ "$certmgr_pods" == *"Running"* ]]; then
        pass "cert-manager is running"
    else
        fail "cert-manager is not running"
    fi

    section "Rancher"
    local rancher_pods
    rancher_pods=$(kubectl --context kind-kube-world -n cattle-system get pods -l app=rancher -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
    if [[ "$rancher_pods" == *"Running"* ]]; then
        pass "Rancher is running"

        # Check Rancher ingress
        local rancher_host
        rancher_host=$(kubectl --context kind-kube-world -n cattle-system get ingress rancher -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
        if [[ -n "$rancher_host" ]]; then
            info "Rancher hostname: ${rancher_host}"
            if [[ "$rancher_host" == "localhost" ]]; then
                warn "Rancher hostname is 'localhost' - Pi will not be able to connect"
                warn "Update with: helm upgrade rancher rancher-stable/rancher -n cattle-system --set hostname=rancher.<your-ip>.nip.io"
            fi

            # Test HTTPS access
            local http_code
            http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${rancher_host}/ping" 2>/dev/null || echo "000")
            if [[ "$http_code" == "200" ]]; then
                pass "Rancher API is accessible via HTTPS"
            else
                fail "Rancher API is not accessible (HTTP ${http_code})"
            fi
        fi
    else
        fail "Rancher is not running"
        kubectl --context kind-kube-world -n cattle-system get pods 2>/dev/null || true
    fi

    section "Fleet"
    if kubectl --context kind-kube-world get namespace cattle-fleet-system &>/dev/null; then
        pass "Fleet namespace exists"
        local fleet_pods
        fleet_pods=$(kubectl --context kind-kube-world -n cattle-fleet-system get pods -l app=fleet-controller -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo "")
        if [[ "$fleet_pods" == *"Running"* ]]; then
            pass "Fleet controller is running"
        else
            warn "Fleet controller may not be ready yet"
        fi
    else
        warn "Fleet namespace not found (Rancher may still be initializing)"
    fi
}

#===============================================================================
# Pi Cluster Checks
#===============================================================================
check_pi_cluster() {
    header "Pi Cluster Health Check"

    # Try to get Pi IP from inventory
    local pi_ip=""
    if [[ -f "${REPO_ROOT}/pi-setup/inventory.ini" ]]; then
        pi_ip=$(grep "ansible_host" "${REPO_ROOT}/pi-setup/inventory.ini" 2>/dev/null | head -1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || echo "")
    fi

    if [[ -z "$pi_ip" ]]; then
        warn "Could not determine Pi IP from inventory"
        info "Using default: 192.168.4.185"
        pi_ip="192.168.4.185"
    fi

    section "Network Connectivity"
    if ping -c 1 -W 3 "$pi_ip" &>/dev/null; then
        pass "Pi is reachable at ${pi_ip}"
    else
        fail "Pi is not reachable at ${pi_ip}"
        return 1
    fi

    section "SSH Connectivity"
    if ssh -o ConnectTimeout=5 -o BatchMode=yes "admin@${pi_ip}" "echo 'SSH OK'" &>/dev/null; then
        pass "SSH connection successful"
    else
        fail "SSH connection failed"
        info "Try: ssh-keygen -R ${pi_ip}"
        return 1
    fi

    section "K3s Service"
    local k3s_status
    k3s_status=$(ssh -o ConnectTimeout=10 "admin@${pi_ip}" "sudo systemctl is-active k3s" 2>/dev/null || echo "inactive")
    if [[ "$k3s_status" == "active" ]]; then
        pass "K3s service is running"
    else
        fail "K3s service is not running (status: ${k3s_status})"
        [[ "$AUTO_FIX" == "true" ]] && { info "Starting K3s..."; ssh "admin@${pi_ip}" "sudo systemctl start k3s" 2>/dev/null || true; }
    fi

    section "K3s Cluster Status"
    local node_status
    node_status=$(ssh -o ConnectTimeout=10 "admin@${pi_ip}" "kubectl get nodes -o jsonpath='{.items[*].status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null || echo "")
    if [[ "$node_status" == *"True"* ]]; then
        pass "K3s nodes are Ready"
    else
        fail "K3s nodes are not Ready"
    fi

    section "System Resources"
    local mem_info
    mem_info=$(ssh -o ConnectTimeout=10 "admin@${pi_ip}" "free -h | grep Mem | awk '{print \$2, \$3, \$4}'" 2>/dev/null || echo "unknown")
    info "Memory (total/used/free): ${mem_info}"

    local disk_info
    disk_info=$(ssh -o ConnectTimeout=10 "admin@${pi_ip}" "df -h / | tail -1 | awk '{print \$2, \$3, \$4}'" 2>/dev/null || echo "unknown")
    info "Disk (total/used/free): ${disk_info}"

    local load_info
    load_info=$(ssh -o ConnectTimeout=10 "admin@${pi_ip}" "cat /proc/loadavg | awk '{print \$1, \$2, \$3}'" 2>/dev/null || echo "unknown")
    info "Load average (1/5/15 min): ${load_info}"

    section "WiFi Status"
    local wifi_status
    wifi_status=$(ssh -o ConnectTimeout=10 "admin@${pi_ip}" "iwconfig wlan0 2>/dev/null | grep 'Link Quality'" 2>/dev/null || echo "")
    if [[ -n "$wifi_status" ]]; then
        info "WiFi: ${wifi_status}"
        local power_save
        power_save=$(ssh -o ConnectTimeout=10 "admin@${pi_ip}" "iw dev wlan0 get power_save" 2>/dev/null || echo "")
        if [[ "$power_save" == *"off"* ]]; then
            pass "WiFi power save is disabled"
        else
            warn "WiFi power save may be enabled (can cause disconnects)"
        fi
    else
        info "WiFi status not available (may be using ethernet)"
    fi
}

#===============================================================================
# Network Connectivity Checks
#===============================================================================
check_network() {
    header "Cross-Cluster Network Connectivity"

    # Get Mac LAN IP
    local mac_ip
    mac_ip=$(route -n get default 2>/dev/null | grep interface | awk '{print $2}' | xargs ipconfig getifaddr 2>/dev/null || echo "")
    if [[ -z "$mac_ip" ]]; then
        mac_ip=$(ifconfig en0 2>/dev/null | grep "inet " | awk '{print $2}' || echo "")
    fi

    # Get Pi IP
    local pi_ip=""
    if [[ -f "${REPO_ROOT}/pi-setup/inventory.ini" ]]; then
        pi_ip=$(grep "ansible_host" "${REPO_ROOT}/pi-setup/inventory.ini" 2>/dev/null | head -1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || echo "192.168.4.185")
    fi

    info "Mac LAN IP: ${mac_ip:-unknown}"
    info "Pi IP: ${pi_ip:-unknown}"

    section "Mac -> Pi Connectivity"
    if [[ -n "$pi_ip" ]]; then
        if ping -c 1 -W 3 "$pi_ip" &>/dev/null; then
            pass "Mac can ping Pi"
        else
            fail "Mac cannot ping Pi"
        fi

        if nc -z -w 3 "$pi_ip" 22 &>/dev/null; then
            pass "Pi SSH port (22) is reachable from Mac"
        else
            fail "Pi SSH port (22) is not reachable from Mac"
        fi

        if nc -z -w 3 "$pi_ip" 6443 &>/dev/null; then
            pass "Pi K3s API (6443) is reachable from Mac"
        else
            info "Pi K3s API (6443) not reachable (may be expected if not exposed)"
        fi
    fi

    section "Pi -> Mac Connectivity"
    if [[ -n "$pi_ip" ]] && [[ -n "$mac_ip" ]]; then
        local pi_ping
        pi_ping=$(ssh -o ConnectTimeout=5 "admin@${pi_ip}" "ping -c 1 -W 3 ${mac_ip}" 2>/dev/null && echo "success" || echo "failed")
        if [[ "$pi_ping" == *"success"* ]]; then
            pass "Pi can ping Mac"
        else
            fail "Pi cannot ping Mac"
        fi

        local pi_443
        pi_443=$(ssh -o ConnectTimeout=5 "admin@${pi_ip}" "nc -z -w 3 ${mac_ip} 443 && echo 'open'" 2>/dev/null || echo "closed")
        if [[ "$pi_443" == *"open"* ]]; then
            pass "Mac HTTPS (443) is reachable from Pi"
        else
            fail "Mac HTTPS (443) is not reachable from Pi"
            warn "Check Mac firewall and KIND port mappings"
        fi

        # Get Rancher hostname
        local rancher_host
        rancher_host=$(kubectl --context kind-kube-world -n cattle-system get ingress rancher -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
        if [[ -n "$rancher_host" ]]; then
            local rancher_test
            rancher_test=$(ssh -o ConnectTimeout=10 "admin@${pi_ip}" "curl -k -s -o /dev/null -w '%{http_code}' 'https://${rancher_host}/ping'" 2>/dev/null || echo "000")
            if [[ "$rancher_test" == "200" ]]; then
                pass "Pi can reach Rancher at https://${rancher_host}"
            else
                fail "Pi cannot reach Rancher (HTTP ${rancher_test})"
            fi
        fi
    fi
}

#===============================================================================
# Summary
#===============================================================================
print_summary() {
    header "Health Check Summary"

    echo ""
    echo -e "  ${GREEN}Passed:${NC}   ${PASSED}"
    echo -e "  ${RED}Failed:${NC}   ${FAILED}"
    echo -e "  ${YELLOW}Warnings:${NC} ${WARNINGS}"
    echo ""

    if [[ $FAILED -eq 0 ]]; then
        echo -e "${BOLD}${GREEN}All critical checks passed!${NC}"
    else
        echo -e "${BOLD}${RED}Some checks failed - review above for details${NC}"
    fi

    if [[ $WARNINGS -gt 0 ]]; then
        echo -e "${YELLOW}Some warnings - consider addressing for improved reliability${NC}"
    fi

    echo ""
}

#===============================================================================
# Main
#===============================================================================
main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║            kube-world Infrastructure Health Check             ║${NC}"
    echo -e "${BOLD}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    if [[ "$NETWORK_ONLY" == "true" ]]; then
        check_network
    elif [[ "$MAC_ONLY" == "true" ]]; then
        check_mac_cluster
    elif [[ "$PI_ONLY" == "true" ]]; then
        check_pi_cluster
    else
        check_mac_cluster
        check_pi_cluster
        check_network
    fi

    print_summary

    # Exit with error if any critical checks failed
    [[ $FAILED -gt 0 ]] && exit 1
    exit 0
}

main "$@"
