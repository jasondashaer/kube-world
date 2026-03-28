#!/usr/bin/env bash
#===============================================================================
# Karmada Control Plane Installation Script
# Installs Karmada on a K3s or KIND cluster as the multi-cluster control plane
#
# Prerequisites:
#   - kubectl configured with access to the host cluster
#   - karmadactl installed (brew install karmadactl)
#   - Helm 3 installed
#
# Usage:
#   ./install-karmada.sh [options]
#   Options:
#     --kubeconfig <path>   Path to host cluster kubeconfig (default: ~/.kube/config)
#     --data-dir <path>     Directory for Karmada data (default: ~/.karmada)
#     --dry-run             Show what would be done without executing
#     --verbose             Enable verbose output
#     --help                Show this help message
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Defaults
KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/config}"
KARMADA_DATA_DIR="${HOME}/.karmada"
DRY_RUN=false
VERBOSE=false

# Karmada configuration
KARMADA_APISERVER_REPLICAS=1
KARMADA_ETCD_REPLICAS=1

log() { echo -e "${GREEN}[KARMADA]${NC} $*"; }
warn() { echo -e "${YELLOW}[KARMADA]${NC} $*"; }
error() { echo -e "${RED}[KARMADA]${NC} $*" >&2; }
debug() { [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[KARMADA]${NC} $*"; }

#===============================================================================
# Prerequisite Checks
#===============================================================================
check_prereqs() {
    log "Checking prerequisites..."
    local missing=()

    if ! command -v kubectl &>/dev/null; then
        missing+=("kubectl")
    fi

    if ! command -v karmadactl &>/dev/null; then
        missing+=("karmadactl (install: brew install karmadactl)")
    fi

    if ! command -v helm &>/dev/null; then
        missing+=("helm")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools:"
        for tool in "${missing[@]}"; do
            error "  - $tool"
        done
        exit 1
    fi

    # Verify cluster access
    if ! kubectl cluster-info &>/dev/null; then
        error "Cannot connect to Kubernetes cluster."
        error "Ensure your kubeconfig is correct: $KUBECONFIG_PATH"
        exit 1
    fi

    # Check cluster has sufficient resources
    local node_count
    node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$node_count" -lt 1 ]]; then
        error "No nodes found in cluster. Is the cluster running?"
        exit 1
    fi

    log "Prerequisites OK (${node_count} node(s) in cluster)"
}

#===============================================================================
# Detect Host Cluster Type
#===============================================================================
detect_cluster_type() {
    if kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "kind"; then
        echo "kind"
    elif kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "k3s"; then
        echo "k3s"
    elif command -v k3s &>/dev/null; then
        echo "k3s"
    else
        echo "generic"
    fi
}

#===============================================================================
# Install Karmada Control Plane
#===============================================================================
install_karmada() {
    local cluster_type
    cluster_type=$(detect_cluster_type)
    log "Detected host cluster type: ${cluster_type}"

    # Check if Karmada is already installed
    if kubectl get namespace karmada-system &>/dev/null; then
        if kubectl -n karmada-system get deployment karmada-apiserver &>/dev/null; then
            log "Karmada control plane already installed."
            log "To reinstall, first run: karmadactl deinit"
            return 0
        fi
    fi

    # Create data directory
    mkdir -p "${KARMADA_DATA_DIR}"

    log "Installing Karmada control plane..."
    log "  API Server replicas: ${KARMADA_APISERVER_REPLICAS}"
    log "  etcd replicas: ${KARMADA_ETCD_REPLICAS}"
    log "  Data directory: ${KARMADA_DATA_DIR}"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would run: karmadactl init"
        return 0
    fi

    # For KIND clusters, we may need to adjust resource requests
    local extra_args=""
    if [[ "$cluster_type" == "kind" ]]; then
        log "KIND cluster detected - using development resource settings"
        # KIND clusters have limited resources, reduce Karmada footprint
        extra_args="--karmada-apiserver-replicas=${KARMADA_APISERVER_REPLICAS} --etcd-replicas=${KARMADA_ETCD_REPLICAS}"
    fi

    # Initialize Karmada
    # karmadactl init deploys: karmada-apiserver, karmada-controller-manager,
    # karmada-scheduler, karmada-webhook, karmada-aggregated-apiserver, etcd
    karmadactl init \
        --kubeconfig="${KUBECONFIG_PATH}" \
        --karmada-data="${KARMADA_DATA_DIR}" \
        --karmada-pki="${KARMADA_DATA_DIR}/pki" \
        --karmada-apiserver-replicas="${KARMADA_APISERVER_REPLICAS}" \
        --etcd-replicas="${KARMADA_ETCD_REPLICAS}" \
        --etcd-storage-mode=hostPath

    log "Karmada control plane installed"
}

#===============================================================================
# Verify Installation
#===============================================================================
verify_installation() {
    log "Verifying Karmada installation..."

    local karmada_config="${KARMADA_DATA_DIR}/karmada-apiserver.config"

    if [[ ! -f "$karmada_config" ]]; then
        error "Karmada config not found at: ${karmada_config}"
        error "Installation may have failed. Check: kubectl -n karmada-system get pods"
        return 1
    fi

    # Wait for all Karmada components
    log "Waiting for Karmada pods to be ready..."
    local timeout=300
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local not_ready
        not_ready=$(kubectl -n karmada-system get pods --no-headers 2>/dev/null | grep -cv "Running\|Completed" || echo "0")
        if [[ "$not_ready" == "0" ]]; then
            break
        fi
        debug "Waiting for ${not_ready} pod(s)... (${elapsed}/${timeout}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    if [[ $elapsed -ge $timeout ]]; then
        warn "Some Karmada pods may not be fully ready:"
        kubectl -n karmada-system get pods
        return 1
    fi

    # Verify Karmada API is responding
    log "Testing Karmada API..."
    if karmadactl get clusters --kubeconfig="${karmada_config}" &>/dev/null; then
        log "Karmada API is responding"
    else
        warn "Karmada API not responding yet. It may take a minute to fully start."
        warn "Test manually: karmadactl get clusters --kubeconfig=${karmada_config}"
    fi

    # Print status
    echo ""
    echo "=============================================="
    echo "  Karmada Control Plane Status"
    echo "=============================================="
    kubectl -n karmada-system get pods
    echo ""
    echo "  Karmada kubeconfig: ${karmada_config}"
    echo ""
    echo "  To use Karmada API:"
    echo "    export KUBECONFIG=${karmada_config}"
    echo "    karmadactl get clusters"
    echo ""
    echo "  To register a cluster:"
    echo "    karmadactl join <cluster-name> \\"
    echo "      --kubeconfig=${karmada_config} \\"
    echo "      --cluster-kubeconfig=<path-to-cluster-kubeconfig>"
    echo ""

    log "Karmada installation verified"
}

#===============================================================================
# Register Host Cluster as Member (optional)
#===============================================================================
register_host_cluster() {
    local karmada_config="${KARMADA_DATA_DIR}/karmada-apiserver.config"
    local cluster_name="${1:-host-cluster}"

    log "Registering host cluster '${cluster_name}' as Karmada member..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would register host cluster"
        return 0
    fi

    # Check if already registered
    if karmadactl get clusters --kubeconfig="${karmada_config}" 2>/dev/null | grep -q "${cluster_name}"; then
        log "Cluster '${cluster_name}' already registered with Karmada"
        return 0
    fi

    karmadactl join "${cluster_name}" \
        --kubeconfig="${karmada_config}" \
        --cluster-kubeconfig="${KUBECONFIG_PATH}" \
        --cluster-context="$(kubectl config current-context)"

    log "Host cluster '${cluster_name}' registered"

    # Verify
    karmadactl get clusters --kubeconfig="${karmada_config}"
}

#===============================================================================
# Parse Arguments
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --kubeconfig)
                KUBECONFIG_PATH="$2"
                shift 2
                ;;
            --data-dir)
                KARMADA_DATA_DIR="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --kubeconfig <path>   Path to host cluster kubeconfig (default: ~/.kube/config)"
                echo "  --data-dir <path>     Directory for Karmada data (default: ~/.karmada)"
                echo "  --dry-run             Show what would be done"
                echo "  --verbose             Enable verbose output"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                error "Run '$0 --help' for usage"
                exit 1
                ;;
        esac
    done
}

#===============================================================================
# Main
#===============================================================================
main() {
    echo ""
    echo "=============================================="
    echo "  Karmada Control Plane Installation"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="
    echo ""

    parse_args "$@"

    check_prereqs
    install_karmada
    verify_installation

    # Optionally register the host cluster as a member
    local cluster_type
    cluster_type=$(detect_cluster_type)
    local cluster_name="kube-world-${cluster_type}"
    register_host_cluster "${cluster_name}"

    echo ""
    echo "=============================================="
    echo "  Karmada Installation Complete!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Register edge clusters: ./karmada/cluster-registration/register-pi.sh"
    echo "  2. Apply propagation policies: kubectl --kubeconfig=${KARMADA_DATA_DIR}/karmada-apiserver.config apply -f karmada/propagation-policies/"
    echo "  3. Install Flux for GitOps: flux bootstrap github ..."
    echo ""
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
