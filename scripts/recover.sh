#!/usr/bin/env bash
#===============================================================================
# Recovery Script for kube-world
#
# Automated recovery for common failure scenarios:
#   - Stuck Kubernetes finalizers
#   - Rancher not accessible
#   - K3s service failures on Pi
#   - Network connectivity issues
#   - Helm release issues
#
# USAGE:
#   ./scripts/recover.sh <scenario>
#
# SCENARIOS:
#   stuck-ns         Remove stuck namespaces with finalizers
#   rancher          Restart/repair Rancher
#   ingress          Reinstall ingress controller
#   pi-k3s           Restart K3s on Pi
#   pi-network       Fix Pi network issues
#   mac-cluster      Reset Mac KIND cluster (destructive)
#   full-reset       Complete reset (destructive)
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
NC='\033[0m'

log() { echo -e "${GREEN}[RECOVER]${NC} $*"; }
warn() { echo -e "${YELLOW}[RECOVER]${NC} $*"; }
error() { echo -e "${RED}[RECOVER]${NC} $*" >&2; }
info() { echo -e "${BLUE}[RECOVER]${NC} $*"; }

#===============================================================================
# Get Pi IP from inventory
#===============================================================================
get_pi_ip() {
    local pi_ip=""
    if [[ -f "${REPO_ROOT}/pi-setup/inventory.ini" ]]; then
        pi_ip=$(grep "ansible_host" "${REPO_ROOT}/pi-setup/inventory.ini" 2>/dev/null | head -1 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || echo "")
    fi
    echo "${pi_ip:-192.168.4.185}"
}

#===============================================================================
# Remove Stuck Namespace Finalizers
#===============================================================================
recover_stuck_namespaces() {
    log "Looking for stuck namespaces..."

    local stuck_namespaces
    stuck_namespaces=$(kubectl get namespace -o jsonpath='{range .items[?(@.status.phase=="Terminating")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || echo "")

    if [[ -z "$stuck_namespaces" ]]; then
        log "No stuck namespaces found"
        return 0
    fi

    warn "Found terminating namespaces:"
    echo "$stuck_namespaces" | sed 's/^/  /'

    read -p "Remove finalizers from these namespaces? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        return 0
    fi

    for ns in $stuck_namespaces; do
        log "Removing finalizers from namespace: $ns"

        # Get the namespace JSON
        kubectl get namespace "$ns" -o json | \
            jq '.spec.finalizers = []' | \
            kubectl replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true

        # Also try patching
        kubectl patch namespace "$ns" --type='merge' -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    done

    log "Finalizers removed. Waiting for namespaces to delete..."
    sleep 5
    kubectl get namespace | grep -E "Terminating" || log "All stuck namespaces cleared"
}

#===============================================================================
# Recover Rancher
#===============================================================================
recover_rancher() {
    log "Attempting Rancher recovery..."

    # Check current state
    local rancher_pods
    rancher_pods=$(kubectl -n cattle-system get pods -l app=rancher --no-headers 2>/dev/null | wc -l || echo "0")

    if [[ "$rancher_pods" -eq 0 ]]; then
        warn "No Rancher pods found. Checking if Helm release exists..."
        if helm status rancher -n cattle-system &>/dev/null; then
            log "Helm release exists but pods missing. Restarting..."
            kubectl -n cattle-system rollout restart deployment/rancher
        else
            error "Rancher not installed. Run: ./rancher/install-rancher.sh"
            return 1
        fi
    fi

    # Restart Rancher deployment
    log "Restarting Rancher deployment..."
    kubectl -n cattle-system rollout restart deployment/rancher

    # Wait for rollout
    log "Waiting for Rancher to restart (this may take several minutes)..."
    kubectl -n cattle-system rollout status deployment/rancher --timeout=300s || {
        warn "Rollout not complete within timeout"
        kubectl -n cattle-system get pods
    }

    # Check webhook
    if kubectl -n cattle-system get deployment rancher-webhook &>/dev/null; then
        log "Restarting Rancher webhook..."
        kubectl -n cattle-system rollout restart deployment/rancher-webhook
    fi

    # Verify access
    local rancher_host
    rancher_host=$(kubectl -n cattle-system get ingress rancher -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
    if [[ -n "$rancher_host" ]]; then
        sleep 10
        local http_code
        http_code=$(curl -k -s -o /dev/null -w "%{http_code}" "https://${rancher_host}/ping" 2>/dev/null || echo "000")
        if [[ "$http_code" == "200" ]]; then
            log "Rancher is accessible at: https://${rancher_host}"
        else
            warn "Rancher may not be fully ready yet (HTTP ${http_code})"
        fi
    fi
}

#===============================================================================
# Recover Ingress Controller
#===============================================================================
recover_ingress() {
    log "Recovering ingress controller..."

    # Check if already installed
    if kubectl -n ingress-nginx get pods -l app.kubernetes.io/name=ingress-nginx --no-headers 2>/dev/null | grep -q Running; then
        log "Ingress controller is running. Restarting..."
        kubectl -n ingress-nginx rollout restart deployment/ingress-nginx-controller
    else
        log "Installing ingress controller..."

        # Create values file
        cat > /tmp/ingress-nginx-values.yaml << 'EOF'
controller:
  hostPort:
    enabled: true
  service:
    type: NodePort
  watchIngressWithoutClass: true
  nodeSelector:
    kubernetes.io/os: linux
    ingress-ready: "true"
  tolerations:
    - operator: "Exists"
  admissionWebhooks:
    enabled: false
EOF

        kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -

        helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
        helm repo update

        helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
            --namespace ingress-nginx \
            -f /tmp/ingress-nginx-values.yaml \
            --wait --timeout 5m
    fi

    log "Waiting for ingress controller to be ready..."
    kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=120s

    # Test
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/ 2>/dev/null || echo "000")
    log "Ingress test (HTTP): ${http_code}"
}

#===============================================================================
# Recover Pi K3s
#===============================================================================
recover_pi_k3s() {
    local pi_ip
    pi_ip=$(get_pi_ip)

    log "Connecting to Pi at ${pi_ip}..."

    if ! ssh -o ConnectTimeout=10 "admin@${pi_ip}" "echo 'connected'" &>/dev/null; then
        error "Cannot connect to Pi via SSH"
        return 1
    fi

    log "Checking K3s service status..."
    local k3s_status
    k3s_status=$(ssh "admin@${pi_ip}" "sudo systemctl status k3s --no-pager" 2>/dev/null | head -5 || echo "unknown")
    echo "$k3s_status" | sed 's/^/  /'

    read -p "Restart K3s service? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Restarting K3s..."
        ssh "admin@${pi_ip}" "sudo systemctl restart k3s"
        sleep 10

        log "Checking cluster status..."
        ssh "admin@${pi_ip}" "kubectl get nodes" || true
    fi
}

#===============================================================================
# Recover Pi Network
#===============================================================================
recover_pi_network() {
    local pi_ip
    pi_ip=$(get_pi_ip)

    log "Attempting Pi network recovery..."

    # First try ping
    if ping -c 1 -W 5 "$pi_ip" &>/dev/null; then
        log "Pi is pingable"
    else
        warn "Pi is not responding to ping"
        info "If using WiFi, the Pi may have disconnected"
        info "Options:"
        info "  1. Power cycle the Pi"
        info "  2. Connect via ethernet"
        info "  3. Check router for DHCP leases"
        return 1
    fi

    # SSH in and fix WiFi
    if ssh -o ConnectTimeout=10 "admin@${pi_ip}" "echo 'connected'" &>/dev/null; then
        log "Disabling WiFi power save..."
        ssh "admin@${pi_ip}" "sudo iw dev wlan0 set power_save off" 2>/dev/null || true

        log "Restarting networking..."
        ssh "admin@${pi_ip}" "sudo systemctl restart NetworkManager 2>/dev/null || sudo systemctl restart networking 2>/dev/null || true"

        log "Current network status:"
        ssh "admin@${pi_ip}" "ip addr show wlan0 2>/dev/null | grep inet || ip addr show eth0 | grep inet"
    else
        error "Cannot establish SSH connection"
    fi
}

#===============================================================================
# Reset Mac KIND Cluster (Destructive)
#===============================================================================
recover_mac_cluster() {
    warn "This will DELETE the KIND cluster and all data!"
    read -p "Are you sure? Type 'yes' to confirm: " confirm
    if [[ "$confirm" != "yes" ]]; then
        log "Aborted"
        return 0
    fi

    log "Deleting KIND cluster..."
    kind delete cluster --name kube-world 2>/dev/null || true

    log "Cleaning up Docker..."
    docker ps -a --filter "name=kube-world" -q 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true

    log "Creating new KIND cluster..."
    kind create cluster --name kube-world --config "${REPO_ROOT}/clusters/mac-local.yaml"

    log "Setting kubectl context..."
    kubectl config use-context kind-kube-world

    log "KIND cluster recreated. Next steps:"
    info "  1. Install ingress: ./scripts/recover.sh ingress"
    info "  2. Install Rancher: ./rancher/install-rancher.sh"
}

#===============================================================================
# Full Reset (Most Destructive)
#===============================================================================
recover_full_reset() {
    warn "╔════════════════════════════════════════════════════════════════╗"
    warn "║  FULL RESET - This will DELETE everything and start fresh!    ║"
    warn "╚════════════════════════════════════════════════════════════════╝"
    warn ""
    warn "This will:"
    warn "  - Delete the Mac KIND cluster and all workloads"
    warn "  - Optionally uninstall K3s from Pi"
    warn ""
    read -p "Are you absolutely sure? Type 'RESET' to confirm: " confirm
    if [[ "$confirm" != "RESET" ]]; then
        log "Aborted"
        return 0
    fi

    log "Starting full reset..."

    # Mac cleanup
    log "Cleaning up Mac cluster..."
    "${REPO_ROOT}/bootstrap.sh" --cleanup --platform mac 2>/dev/null || true
    kind delete cluster --name kube-world 2>/dev/null || true

    # Pi cleanup (optional)
    local pi_ip
    pi_ip=$(get_pi_ip)
    read -p "Also reset Pi K3s at ${pi_ip}? [y/N] " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        log "Uninstalling K3s from Pi..."
        ssh "admin@${pi_ip}" "sudo /usr/local/bin/k3s-uninstall.sh 2>/dev/null || true"
    fi

    log "Full reset complete."
    info ""
    info "To rebuild:"
    info "  Mac cluster:  ./bootstrap.sh --platform mac"
    info "  Pi cluster:   ./bootstrap.sh --platform pi"
}

#===============================================================================
# Show Help
#===============================================================================
show_help() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                         kube-world Recovery Script                             ║
╚═══════════════════════════════════════════════════════════════════════════════╝

USAGE:
    ./scripts/recover.sh <scenario>

SCENARIOS:
    stuck-ns         Remove stuck namespaces with finalizers
    rancher          Restart/repair Rancher
    ingress          Reinstall ingress controller
    pi-k3s           Restart K3s on Pi
    pi-network       Fix Pi network issues (WiFi power save, etc.)
    mac-cluster      Reset Mac KIND cluster (DESTRUCTIVE)
    full-reset       Complete reset of everything (MOST DESTRUCTIVE)

EXAMPLES:
    # Fix stuck terminating namespaces
    ./scripts/recover.sh stuck-ns

    # Restart Rancher if it's not responding
    ./scripts/recover.sh rancher

    # Fix WiFi issues on Pi
    ./scripts/recover.sh pi-network

EOF
}

#===============================================================================
# Main
#===============================================================================
main() {
    if [[ $# -lt 1 ]]; then
        show_help
        exit 0
    fi

    case "$1" in
        stuck-ns)
            recover_stuck_namespaces
            ;;
        rancher)
            recover_rancher
            ;;
        ingress)
            recover_ingress
            ;;
        pi-k3s)
            recover_pi_k3s
            ;;
        pi-network)
            recover_pi_network
            ;;
        mac-cluster)
            recover_mac_cluster
            ;;
        full-reset)
            recover_full_reset
            ;;
        -h|--help)
            show_help
            ;;
        *)
            error "Unknown scenario: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
