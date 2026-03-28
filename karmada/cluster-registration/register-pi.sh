#!/usr/bin/env bash
#===============================================================================
# Register Raspberry Pi K3s Cluster with Karmada
# Joins a Pi cluster as a Karmada member for multi-cluster scheduling
#
# Prerequisites:
#   - Karmada control plane installed (./karmada/install-karmada.sh)
#   - Pi K3s cluster running and accessible
#   - Pi kubeconfig available locally
#
# Usage:
#   ./register-pi.sh [options]
#   Options:
#     --cluster-name <name>       Name for this cluster in Karmada (default: pi-cluster)
#     --cluster-kubeconfig <path> Path to Pi cluster kubeconfig (default: ~/.kube/pi-config)
#     --karmada-config <path>     Path to Karmada API kubeconfig (default: ~/.karmada/karmada-apiserver.config)
#     --pi-ip <ip>               Pi IP address (for kubeconfig fetch)
#     --labels <k=v,k=v>         Cluster labels (default: topology=edge,hardware=raspberry-pi,workload-type=iot)
#     --help                      Show this help
#===============================================================================
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Defaults
CLUSTER_NAME="pi-cluster"
CLUSTER_KUBECONFIG="${HOME}/.kube/pi-config"
KARMADA_CONFIG="${HOME}/.karmada/karmada-apiserver.config"
PI_IP=""
CLUSTER_LABELS="topology.kubernetes.io/zone=edge,hardware=raspberry-pi,workload-type=iot"

log() { echo -e "${GREEN}[REGISTER]${NC} $*"; }
warn() { echo -e "${YELLOW}[REGISTER]${NC} $*"; }
error() { echo -e "${RED}[REGISTER]${NC} $*" >&2; }

#===============================================================================
# Fetch Pi Kubeconfig
#===============================================================================
fetch_pi_kubeconfig() {
    local pi_ip="$1"
    local dest="$2"

    log "Fetching kubeconfig from Pi at ${pi_ip}..."

    # Try to copy kubeconfig from Pi
    if scp -o ConnectTimeout=10 "admin@${pi_ip}:/etc/rancher/k3s/k3s.yaml" "${dest}" 2>/dev/null; then
        # Replace localhost with actual Pi IP in kubeconfig
        if [[ "$(uname -s)" == "Darwin" ]]; then
            sed -i '' "s/127.0.0.1/${pi_ip}/g" "${dest}"
        else
            sed -i "s/127.0.0.1/${pi_ip}/g" "${dest}"
        fi
        log "Kubeconfig fetched and updated with Pi IP"
    else
        error "Could not fetch kubeconfig from Pi. Ensure:"
        error "  1. SSH access works: ssh admin@${pi_ip}"
        error "  2. K3s is running: ssh admin@${pi_ip} sudo systemctl status k3s"
        exit 1
    fi
}

#===============================================================================
# Verify Cluster Access
#===============================================================================
verify_cluster_access() {
    local kubeconfig="$1"
    local name="$2"

    log "Verifying access to ${name}..."

    if ! kubectl --kubeconfig="${kubeconfig}" get nodes &>/dev/null; then
        error "Cannot connect to ${name} cluster using: ${kubeconfig}"
        return 1
    fi

    local node_info
    node_info=$(kubectl --kubeconfig="${kubeconfig}" get nodes -o wide --no-headers 2>/dev/null | head -1)
    log "  ${name}: ${node_info}"
    return 0
}

#===============================================================================
# Register Cluster
#===============================================================================
register_cluster() {
    log "Registering '${CLUSTER_NAME}' with Karmada..."

    # Check if already registered
    if karmadactl get clusters --kubeconfig="${KARMADA_CONFIG}" 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
        log "Cluster '${CLUSTER_NAME}' is already registered with Karmada"
        karmadactl get clusters --kubeconfig="${KARMADA_CONFIG}"
        return 0
    fi

    # Join the cluster
    karmadactl join "${CLUSTER_NAME}" \
        --kubeconfig="${KARMADA_CONFIG}" \
        --cluster-kubeconfig="${CLUSTER_KUBECONFIG}"

    log "Cluster '${CLUSTER_NAME}' registered"

    # Apply labels
    if [[ -n "${CLUSTER_LABELS}" ]]; then
        log "Applying cluster labels..."
        IFS=',' read -ra LABELS <<< "${CLUSTER_LABELS}"
        for label in "${LABELS[@]}"; do
            kubectl --kubeconfig="${KARMADA_CONFIG}" label cluster "${CLUSTER_NAME}" "${label}" --overwrite 2>/dev/null || true
        done
        log "Labels applied: ${CLUSTER_LABELS}"
    fi
}

#===============================================================================
# Verify Registration
#===============================================================================
verify_registration() {
    log "Verifying Karmada registration..."

    echo ""
    echo "=============================================="
    echo "  Karmada Cluster Status"
    echo "=============================================="
    karmadactl get clusters --kubeconfig="${KARMADA_CONFIG}"

    echo ""
    echo "  Cluster labels:"
    kubectl --kubeconfig="${KARMADA_CONFIG}" get cluster "${CLUSTER_NAME}" -o jsonpath='{.metadata.labels}' 2>/dev/null | python3 -m json.tool 2>/dev/null || true
    echo ""

    # Test scheduling by checking if Karmada can reach the cluster
    local cluster_status
    cluster_status=$(kubectl --kubeconfig="${KARMADA_CONFIG}" get cluster "${CLUSTER_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "${cluster_status}" == "True" ]]; then
        log "Cluster '${CLUSTER_NAME}' is Ready in Karmada"
    else
        warn "Cluster '${CLUSTER_NAME}' may not be fully ready yet. Status: ${cluster_status}"
        warn "This can take a minute. Check with:"
        warn "  karmadactl get clusters --kubeconfig=${KARMADA_CONFIG}"
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Register with Rancher: ./pi-setup/join-cluster.sh"
    echo "  2. Apply propagation policies: kubectl --kubeconfig=${KARMADA_CONFIG} apply -f karmada/propagation-policies/"
    echo "  3. Deploy workloads via Flux or directly to Karmada API"
    echo ""
}

#===============================================================================
# Parse Arguments
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --cluster-name)
                CLUSTER_NAME="$2"
                shift 2
                ;;
            --cluster-kubeconfig)
                CLUSTER_KUBECONFIG="$2"
                shift 2
                ;;
            --karmada-config)
                KARMADA_CONFIG="$2"
                shift 2
                ;;
            --pi-ip)
                PI_IP="$2"
                shift 2
                ;;
            --labels)
                CLUSTER_LABELS="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --cluster-name <name>       Cluster name in Karmada (default: pi-cluster)"
                echo "  --cluster-kubeconfig <path>  Path to Pi kubeconfig (default: ~/.kube/pi-config)"
                echo "  --karmada-config <path>      Karmada API kubeconfig (default: ~/.karmada/karmada-apiserver.config)"
                echo "  --pi-ip <ip>                 Pi IP (fetches kubeconfig via SSH)"
                echo "  --labels <k=v,k=v>           Cluster labels (default: topology=edge,hardware=raspberry-pi,workload-type=iot)"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

#===============================================================================
# Main
#===============================================================================
main() {
    parse_args "$@"

    log "Registering Pi cluster with Karmada"
    log "  Cluster name: ${CLUSTER_NAME}"
    log "  Labels: ${CLUSTER_LABELS}"

    # Fetch kubeconfig from Pi if IP provided
    if [[ -n "${PI_IP}" ]]; then
        fetch_pi_kubeconfig "${PI_IP}" "${CLUSTER_KUBECONFIG}"
    fi

    # Verify access to both clusters
    verify_cluster_access "${KARMADA_CONFIG}" "Karmada API"
    verify_cluster_access "${CLUSTER_KUBECONFIG}" "${CLUSTER_NAME}"

    # Register
    register_cluster

    # Verify
    verify_registration
}

main "$@"
