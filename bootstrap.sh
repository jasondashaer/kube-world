#!/usr/bin/env bash
#===============================================================================
# kube-world Bootstrap Script
# Purpose: Single-command setup for entire Kubernetes orchestration platform
# Usage: ./bootstrap.sh [options]
# Options:
#   --platform <mac|pi|cloud>  Target platform (default: auto-detect)
#   --mode <dev|prod>          Deployment mode (default: dev)
#   --skip-prereqs             Skip prerequisite installation
#   --dry-run                  Show what would be done without executing
#   --cleanup                  Tear down existing setup before rebuilding
#   --verbose                  Enable verbose output
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/.bootstrap.log"
KUBECONFIG_DIR="${HOME}/.kube"
K3S_VERSION="${K3S_VERSION:-v1.29.0+k3s1}"
RANCHER_VERSION="${RANCHER_VERSION:-2.13.1}"
HELM_VERSION="${HELM_VERSION:-3.14.0}"

# Default options
PLATFORM=""
MODE="dev"
SKIP_PREREQS=false
DRY_RUN=false
CLEANUP=false
VERBOSE=false

#===============================================================================
# Logging Functions
#===============================================================================
log() { echo -e "${GREEN}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*" | tee -a "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE" >&2; }
debug() { [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*" | tee -a "$LOG_FILE"; }

#===============================================================================
# Utility Functions
#===============================================================================

# Wait for a CRD to be available in the cluster
# Usage: wait_for_crd <crd-name> [timeout_seconds]
wait_for_crd() {
    local crd_name="$1"
    local timeout="${2:-300}"  # Default 5 minutes
    local interval=5
    local elapsed=0
    
    log "Waiting for CRD '${crd_name}' to be available..."
    
    while [[ $elapsed -lt $timeout ]]; do
        if kubectl get crd "${crd_name}" &>/dev/null; then
            log "CRD '${crd_name}' is available ✓"
            return 0
        fi
        debug "CRD '${crd_name}' not yet available, waiting ${interval}s... (${elapsed}/${timeout}s)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done
    
    error "Timeout waiting for CRD '${crd_name}' after ${timeout}s"
    return 1
}

# Wait for Fleet CRDs specifically (installed by Rancher)
wait_for_fleet_crds() {
    log "Waiting for Fleet CRDs to be installed by Rancher..."
    
    local fleet_crds=(
        "gitrepos.fleet.cattle.io"
        "bundles.fleet.cattle.io"
        "clustergroups.fleet.cattle.io"
        "clusters.fleet.cattle.io"
    )
    
    for crd in "${fleet_crds[@]}"; do
        if ! wait_for_crd "$crd" 300; then
            error "Fleet CRD '$crd' not available. Is Rancher fully installed?"
            return 1
        fi
    done
    
    # Also wait for fleet-controller to be ready
    log "Waiting for Fleet controller to be ready..."
    kubectl wait --for=condition=Available deployment/fleet-controller \
        -n cattle-fleet-system --timeout=300s 2>/dev/null || \
    kubectl wait --for=condition=Available deployment/fleet-controller \
        -n fleet-system --timeout=300s 2>/dev/null || true
    
    log "Fleet CRDs and controller ready ✓"
    return 0
}

detect_platform() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    
    case "$os" in
        darwin)
            if [[ "$arch" == "arm64" ]]; then
                echo "mac-arm64"
            else
                echo "mac-amd64"
            fi
            ;;
        linux)
            if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
                # Check for Raspberry Pi
                if grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
                    echo "pi"
                else
                    echo "linux-arm64"
                fi
            else
                echo "linux-amd64"
            fi
            ;;
        *)
            error "Unsupported OS: $os"
            exit 1
            ;;
    esac
}

check_command() {
    command -v "$1" &>/dev/null
}

install_prereqs_mac() {
    log "Installing prerequisites for macOS..."
    
    # Install Homebrew if not present
    if ! check_command brew; then
        log "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi
    
    # Docker Desktop is required for KIND - cannot be installed via Homebrew easily
    if ! check_command docker; then
        echo ""
        error "Docker Desktop is required but not installed."
        echo ""
        echo "============================================="
        echo "  Docker Desktop Installation Required"
        echo "============================================="
        echo ""
        echo "KIND (Kubernetes in Docker) requires Docker Desktop on macOS."
        echo ""
        echo "Install Docker Desktop:"
        echo "  1. Download from: https://www.docker.com/products/docker-desktop/"
        echo "     (Choose 'Mac with Apple Chip' for M1/M2/M3 Macs)"
        echo ""
        echo "  2. Or install via Homebrew Cask:"
        echo "     brew install --cask docker"
        echo ""
        echo "  3. After installation, launch Docker Desktop from Applications"
        echo "     and wait for it to fully start (whale icon in menu bar)"
        echo ""
        echo "  4. Re-run this bootstrap script"
        echo ""
        echo "Alternative: For Pi deployment, use --platform pi instead."
        echo ""
        
        # Offer to install via Homebrew
        read -p "Would you like to install Docker Desktop via Homebrew now? [y/N] " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Installing Docker Desktop via Homebrew..."
            brew install --cask docker
            echo ""
            warn "Docker Desktop installed. Please launch it from Applications."
            warn "Wait for Docker to fully start, then re-run this script."
            exit 0
        else
            exit 1
        fi
    fi
    
    # Verify Docker daemon is running
    if ! docker info &>/dev/null; then
        echo ""
        error "Docker Desktop is installed but not running."
        echo ""
        echo "Please:"
        echo "  1. Launch Docker Desktop from Applications"
        echo "  2. Wait for it to fully start (whale icon in menu bar stops animating)"
        echo "  3. Re-run this bootstrap script"
        echo ""
        exit 1
    fi
    
    log "Docker Desktop detected and running ✓"
    
    local packages=("kubectl" "helm" "kind" "ansible" "sops" "age" "jq" "yq")
    for pkg in "${packages[@]}"; do
        if ! check_command "$pkg"; then
            log "Installing $pkg..."
            brew install "$pkg"
        else
            debug "$pkg already installed"
        fi
    done
    
    # Install k3sup for remote K3s installation
    if ! check_command k3sup; then
        log "Installing k3sup..."
        brew install k3sup
    fi
}

install_prereqs_linux() {
    log "Installing prerequisites for Linux..."
    
    # Update package list
    sudo apt-get update -qq
    
    # Install basic packages
    sudo apt-get install -y -qq curl wget git jq
    
    # Install kubectl
    if ! check_command kubectl; then
        log "Installing kubectl..."
        curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/$(dpkg --print-architecture)/kubectl"
        sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
        rm kubectl
    fi
    
    # Install Helm
    if ! check_command helm; then
        log "Installing Helm..."
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi
    
    # Install Ansible
    if ! check_command ansible; then
        log "Installing Ansible..."
        sudo apt-get install -y -qq ansible
    fi
    
    # Install SOPS
    if ! check_command sops; then
        log "Installing SOPS..."
        local sops_version="3.8.1"
        local arch
        arch="$(dpkg --print-architecture)"
        curl -LO "https://github.com/getsops/sops/releases/download/v${sops_version}/sops-v${sops_version}.linux.${arch}"
        sudo mv "sops-v${sops_version}.linux.${arch}" /usr/local/bin/sops
        sudo chmod +x /usr/local/bin/sops
    fi
}

preflight_checks() {
    log "Running preflight checks..."
    local checks_passed=true
    
    # Check disk space (need at least 10GB)
    local free_space
    # macOS uses different df options than Linux
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS: df -g shows in GB
        free_space=$(df -g / | awk 'NR==2 {print $4}')
    else
        # Linux: df -BG shows in GB (some systems may not support -B, fallback to -k)
        if df -BG / &>/dev/null; then
            free_space=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
        else
            # Fallback: convert from KB to GB
            free_space=$(df -k / | awk 'NR==2 {print int($4/1024/1024)}')
        fi
    fi
    
    if [[ -n "$free_space" ]] && [[ "$free_space" -lt 10 ]]; then
        warn "Low disk space: ${free_space}GB available (10GB recommended)"
    fi
    
    # Check network connectivity
    if ! curl -s --connect-timeout 5 https://github.com > /dev/null; then
        error "Cannot reach GitHub. Check network connectivity."
        checks_passed=false
    fi
    
    # Check for existing clusters (if not cleanup mode)
    if [[ "$CLEANUP" != "true" ]]; then
        if kubectl cluster-info &>/dev/null; then
            warn "Existing Kubernetes cluster detected. Use --cleanup to remove first."
        fi
    fi
    
    # Platform-specific checks
    case "$PLATFORM" in
        pi)
            # Check cgroup memory
            if ! grep -q "cgroup_memory=1" /proc/cmdline 2>/dev/null; then
                warn "cgroup memory not enabled. Required for K3s."
            fi
            # Check swap
            if [[ $(swapon --show | wc -l) -gt 0 ]]; then
                warn "Swap is enabled. Should be disabled for Kubernetes."
            fi
            ;;
    esac
    
    if [[ "$checks_passed" != "true" ]]; then
        error "Preflight checks failed"
        exit 1
    fi
    
    log "Preflight checks passed ✓"
}

cleanup_existing() {
    log "Cleaning up existing installation..."
    
    case "$PLATFORM" in
        mac-*)
            # Delete KIND cluster if exists
            kind delete cluster --name management 2>/dev/null || true
            kind delete cluster --name kube-world 2>/dev/null || true
            ;;
        pi|linux-*)
            # Uninstall K3s if present
            if [[ -f /usr/local/bin/k3s-uninstall.sh ]]; then
                log "Uninstalling K3s server..."
                sudo /usr/local/bin/k3s-uninstall.sh || true
            fi
            if [[ -f /usr/local/bin/k3s-agent-uninstall.sh ]]; then
                log "Uninstalling K3s agent..."
                sudo /usr/local/bin/k3s-agent-uninstall.sh || true
            fi
            ;;
    esac
    
    log "Cleanup complete ✓"
}

#===============================================================================
# Cluster Setup Functions
#===============================================================================
setup_mac_cluster() {
    log "Setting up local development cluster on Mac..."
    
    # Create KIND cluster with custom config
    if ! kind get clusters | grep -q "kube-world"; then
        log "Creating KIND cluster..."
        kind create cluster --name kube-world --config "${SCRIPT_DIR}/clusters/mac-local.yaml"
    else
        log "KIND cluster 'kube-world' already exists"
    fi
    
    # Set kubectl context
    kubectl config use-context kind-kube-world
    
    # Wait for cluster to be ready
    log "Waiting for cluster to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=300s
    
    log "Mac cluster setup complete ✓"
}

setup_pi_cluster() {
    log "Setting up K3s cluster on Raspberry Pi..."
    
    local inventory="${SCRIPT_DIR}/pi-setup/inventory.ini"
    local playbook="${SCRIPT_DIR}/pi-setup/ansible/playbook.yml"
    
    # Run Ansible playbook for Pi setup
    if [[ -f "$playbook" ]]; then
        ansible-playbook -i "$inventory" "$playbook" \
            -e "k3s_version=${K3S_VERSION}" \
            -e "mode=${MODE}"
    else
        error "Ansible playbook not found at $playbook"
        exit 1
    fi
    
    # Copy kubeconfig from Pi
    local pi_ip
    pi_ip=$(grep -E "^\[masters\]" -A1 "$inventory" | tail -1 | awk '{print $1}')
    
    mkdir -p "$KUBECONFIG_DIR"
    scp "admin@${pi_ip}:/etc/rancher/k3s/k3s.yaml" "${KUBECONFIG_DIR}/pi-config"
    sed -i.bak "s/127.0.0.1/${pi_ip}/g" "${KUBECONFIG_DIR}/pi-config"
    
    export KUBECONFIG="${KUBECONFIG_DIR}/pi-config"
    
    log "Pi cluster setup complete ✓"
}

#===============================================================================
# Rancher Installation
#===============================================================================
install_rancher() {
    log "Installing Rancher..."
    
    # Source the install script
    source "${SCRIPT_DIR}/rancher/install-rancher.sh"
}

#===============================================================================
# GitOps Setup (Fleet)
#===============================================================================
setup_gitops() {
    log "Setting up GitOps with Fleet..."
    
    # CRITICAL: Fleet CRDs are installed asynchronously by Rancher
    # We must wait for them before applying our GitRepo resources
    if ! wait_for_fleet_crds; then
        error "Fleet CRDs not available. Cannot configure GitOps."
        error "This usually means Rancher installation is incomplete."
        error "Check Rancher pods: kubectl -n cattle-system get pods"
        return 1
    fi
    
    # Ensure fleet-local namespace exists (created by Rancher)
    log "Waiting for Fleet namespaces..."
    local ns_timeout=60
    local ns_elapsed=0
    while [[ $ns_elapsed -lt $ns_timeout ]]; do
        if kubectl get namespace fleet-local &>/dev/null; then
            break
        fi
        debug "Waiting for fleet-local namespace..."
        sleep 5
        ns_elapsed=$((ns_elapsed + 5))
    done
    
    # Apply Fleet GitRepo configuration
    log "Applying Fleet GitRepo configuration..."
    if ! kubectl apply -f "${SCRIPT_DIR}/gitops/fleet.yaml"; then
        error "Failed to apply Fleet configuration"
        return 1
    fi
    
    # Create Fleet clusters if needed
    if [[ -f "${SCRIPT_DIR}/gitops/clusters.yaml" ]]; then
        kubectl apply -f "${SCRIPT_DIR}/gitops/clusters.yaml"
    fi
    
    log "GitOps setup complete ✓"
}

#===============================================================================
# Application Deployment
#===============================================================================
deploy_core_apps() {
    log "Deploying core applications..."
    
    # Apply base configurations (excluding fleet.yaml which is processed by Fleet)
    # Fleet bundle configs (fleet.yaml) don't have apiVersion/kind - they're Fleet-specific
    for manifest in "${SCRIPT_DIR}"/apps/base/*.yaml; do
        if [[ -f "$manifest" && "$(basename "$manifest")" != "fleet.yaml" ]]; then
            debug "Applying: $manifest"
            kubectl apply -f "$manifest" 2>/dev/null || true
        fi
    done
    
    # Apply platform-specific configurations
    local platform_apps="${SCRIPT_DIR}/apps/${PLATFORM}/"
    if [[ -d "$platform_apps" ]]; then
        for manifest in "${platform_apps}"*.yaml; do
            if [[ -f "$manifest" && "$(basename "$manifest")" != "fleet.yaml" ]]; then
                debug "Applying: $manifest"
                kubectl apply -f "$manifest" 2>/dev/null || true
            fi
        done
    fi
    
    log "Core apps deployed ✓"
}

#===============================================================================
# Verification
#===============================================================================
verify_installation() {
    log "Verifying installation..."
    
    echo ""
    echo "=============================================="
    echo "CLUSTER STATUS"
    echo "=============================================="
    kubectl get nodes -o wide
    
    echo ""
    echo "=============================================="
    echo "NAMESPACES"
    echo "=============================================="
    kubectl get namespaces
    
    echo ""
    echo "=============================================="
    echo "RANCHER STATUS"
    echo "=============================================="
    kubectl -n cattle-system get pods
    
    echo ""
    echo "=============================================="
    echo "FLEET STATUS"
    echo "=============================================="
    kubectl -n fleet-local get gitrepo 2>/dev/null || echo "Fleet not yet configured"
    
    log "Verification complete ✓"
}

#===============================================================================
# Main Execution
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --platform)
                PLATFORM="$2"
                shift 2
                ;;
            --mode)
                MODE="$2"
                shift 2
                ;;
            --skip-prereqs)
                SKIP_PREREQS=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --cleanup)
                CLEANUP=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --platform <mac|pi|cloud>  Target platform (default: auto-detect)"
                echo "  --mode <dev|prod>          Deployment mode (default: dev)"
                echo "  --skip-prereqs             Skip prerequisite installation"
                echo "  --dry-run                  Show what would be done"
                echo "  --cleanup                  Tear down existing setup"
                echo "  --verbose                  Enable verbose output"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

main() {
    echo ""
    echo "=============================================="
    echo "  kube-world Bootstrap"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="
    echo ""
    
    # Initialize log
    echo "Bootstrap started at $(date)" > "$LOG_FILE"
    
    # Parse arguments
    parse_args "$@"
    
    # Auto-detect platform if not specified or normalize shorthand
    if [[ -z "$PLATFORM" ]]; then
        PLATFORM=$(detect_platform)
    elif [[ "$PLATFORM" == "mac" ]]; then
        # Normalize 'mac' to specific architecture
        PLATFORM=$(detect_platform)
        if [[ "$PLATFORM" != mac-* ]]; then
            PLATFORM="mac-arm64"  # Default to ARM64 for modern Macs
        fi
    fi
    
    log "Platform: $PLATFORM"
    log "Mode: $MODE"
    
    # Dry run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN MODE - no changes will be made"
        echo "Would execute:"
        echo "  1. Install prerequisites"
        echo "  2. Run preflight checks"
        [[ "$CLEANUP" == "true" ]] && echo "  3. Cleanup existing installation"
        echo "  4. Setup ${PLATFORM} cluster"
        echo "  5. Install Rancher"
        echo "  6. Setup GitOps"
        echo "  7. Deploy core apps"
        echo "  8. Verify installation"
        exit 0
    fi
    
    # Cleanup if requested
    if [[ "$CLEANUP" == "true" ]]; then
        cleanup_existing
    fi
    
    # Install prerequisites
    if [[ "$SKIP_PREREQS" != "true" ]]; then
        case "$PLATFORM" in
            mac|mac-*)
                install_prereqs_mac
                ;;
            pi|linux-*)
                install_prereqs_linux
                ;;
        esac
    fi
    
    # Run preflight checks
    preflight_checks
    
    # Setup cluster based on platform
    case "$PLATFORM" in
        mac|mac-*)
            setup_mac_cluster
            ;;
        pi)
            setup_pi_cluster
            ;;
        *)
            error "Platform $PLATFORM not yet implemented"
            exit 1
            ;;
    esac
    
    # Install Rancher
    install_rancher
    
    # Setup GitOps
    setup_gitops
    
    # Deploy core applications
    deploy_core_apps
    
    # Verify installation
    verify_installation
    
    echo ""
    echo "=============================================="
    echo "  Bootstrap Complete! 🎉"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Change Rancher admin password"
    echo "  2. Register additional clusters via Rancher UI"
    echo "  3. Configure secrets in /secrets/ directory"
    echo "  4. Deploy applications via GitOps"
    echo ""
    echo "Logs saved to: $LOG_FILE"
}

main "$@"