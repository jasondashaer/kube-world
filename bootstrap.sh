#!/usr/bin/env bash
#===============================================================================
# kube-world Bootstrap Script
# Purpose: Single-command setup for entire Kubernetes orchestration platform
# Usage: ./bootstrap.sh [options]
# Options:
#   --platform <mac|pi|cloud>  Target platform (default: auto-detect)
#   --mode <dev|prod>          Deployment mode (default: dev)
#   --stack <karmada|fleet>    Orchestration stack (default: karmada)
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
CONFIG_FILE="${SCRIPT_DIR}/config.yaml"

# Load versions from config.yaml if available, otherwise use defaults
load_config_versions() {
    if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
        K3S_VERSION="${K3S_VERSION:-$(yq eval '.deployment.versions.k3s // "v1.29.0+k3s1"' "$CONFIG_FILE")}"
        RANCHER_VERSION="${RANCHER_VERSION:-$(yq eval '.deployment.versions.rancher // "2.13.1"' "$CONFIG_FILE")}"
        HELM_VERSION="${HELM_VERSION:-$(yq eval '.deployment.versions.helm // "3.14.0"' "$CONFIG_FILE")}"
        KARMADA_VERSION="${KARMADA_VERSION:-$(yq eval '.deployment.versions.karmada // "1.12.0"' "$CONFIG_FILE")}"
        FLUX_VERSION="${FLUX_VERSION:-$(yq eval '.deployment.versions.flux // "2.4.0"' "$CONFIG_FILE")}"
    else
        # Fallback to hardcoded defaults if config.yaml not available
        K3S_VERSION="${K3S_VERSION:-v1.29.0+k3s1}"
        RANCHER_VERSION="${RANCHER_VERSION:-2.13.1}"
        HELM_VERSION="${HELM_VERSION:-3.14.0}"
        KARMADA_VERSION="${KARMADA_VERSION:-1.12.0}"
        FLUX_VERSION="${FLUX_VERSION:-2.4.0}"
    fi
}

# Initialize with defaults - will be overwritten by load_config_versions() after yq is installed
K3S_VERSION="${K3S_VERSION:-v1.29.0+k3s1}"
RANCHER_VERSION="${RANCHER_VERSION:-2.13.1}"
HELM_VERSION="${HELM_VERSION:-3.14.0}"
KARMADA_VERSION="${KARMADA_VERSION:-1.12.0}"
FLUX_VERSION="${FLUX_VERSION:-2.4.0}"

# Host OS detection (where the script is running, not the target)
HOST_OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

# Default options
PLATFORM=""
MODE="dev"
STACK="karmada"  # karmada (Karmada+Flux) or fleet (legacy Fleet)
PI_IP=""          # Set during setup_pi_cluster, used in completion messages
SKIP_PREREQS=false
DRY_RUN=false
CLEANUP=false
VERBOSE=false

# Domain — configurable via env or .env.bootstrap, used everywhere
DOMAIN="${DOMAIN:-}"
# Derived hostnames (set in main() after DOMAIN is resolved)
RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-}"
GITLAB_HOSTNAME="${GITLAB_HOSTNAME:-}"

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

    # First, ensure Rancher is FULLY ready (not just deployed)
    log "Verifying Rancher internal components are running..."
    local rancher_ready_timeout=300
    local rancher_elapsed=0
    while [[ $rancher_elapsed -lt $rancher_ready_timeout ]]; do
        # Count running pods more reliably using jsonpath with proper filtering
        local total_pods running_pods
        total_pods=$(kubectl -n cattle-system get pods --no-headers 2>/dev/null | wc -l | tr -d ' ' || echo "0")
        running_pods=$(kubectl -n cattle-system get pods -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | wc -w || echo "0")

        if [[ "$total_pods" -gt 0 && "$running_pods" -ge "$total_pods" ]]; then
            # Also check that fleet-controller namespace exists (created by Rancher)
            if kubectl get namespace cattle-fleet-system &>/dev/null || kubectl get namespace fleet-system &>/dev/null; then
                log "Rancher internal components ready (${running_pods}/${total_pods} pods running) ✓"
                break
            fi
        fi

        # Show progress with pod status
        if [[ $((rancher_elapsed % 30)) -eq 0 && $rancher_elapsed -gt 0 ]]; then
            log "  Progress: ${running_pods}/${total_pods} pods running (${rancher_elapsed}/${rancher_ready_timeout}s)"
            # Show any pods that are not running
            local problem_pods
            problem_pods=$(kubectl -n cattle-system get pods --no-headers 2>/dev/null | grep -v "Running\|Completed\|Succeeded" | head -3 || true)
            if [[ -n "$problem_pods" ]]; then
                debug "  Pods not ready yet:"
                echo "$problem_pods" | while read -r line; do debug "    $line"; done
            fi
        fi

        sleep 10
        rancher_elapsed=$((rancher_elapsed + 10))
    done

    if [[ $rancher_elapsed -ge $rancher_ready_timeout ]]; then
        warn "Rancher internal components may not be fully ready after ${rancher_ready_timeout}s"
        warn "Current pod status:"
        kubectl -n cattle-system get pods
        warn "Continuing anyway - Fleet CRDs may still become available..."
    fi

    local fleet_crds=(
        "gitrepos.fleet.cattle.io"
        "bundles.fleet.cattle.io"
        "clustergroups.fleet.cattle.io"
        "clusters.fleet.cattle.io"
    )

    local failed_crds=()
    for crd in "${fleet_crds[@]}"; do
        if ! wait_for_crd "$crd" 300; then
            failed_crds+=("$crd")
        fi
    done

    if [[ ${#failed_crds[@]} -gt 0 ]]; then
        error "Fleet CRDs not available: ${failed_crds[*]}"
        error ""
        error "Troubleshooting steps:"
        error "  1. Check Rancher pods: kubectl -n cattle-system get pods"
        error "  2. Check Rancher logs: kubectl -n cattle-system logs -l app=rancher --tail=50"
        error "  3. Check available CRDs: kubectl get crd | grep fleet"
        error "  4. Check cluster resources: kubectl top nodes (if metrics-server installed)"
        error ""
        error "Common causes:"
        error "  - Insufficient cluster memory (Rancher needs ~2GB)"
        error "  - Network issues preventing image pulls"
        error "  - Previous incomplete installation (try --cleanup first)"
        return 1
    fi

    # Also wait for fleet-controller to be ready
    log "Waiting for Fleet controller to be ready..."
    local fleet_ns=""
    if kubectl get namespace cattle-fleet-system &>/dev/null; then
        fleet_ns="cattle-fleet-system"
    elif kubectl get namespace fleet-system &>/dev/null; then
        fleet_ns="fleet-system"
    fi

    if [[ -n "$fleet_ns" ]]; then
        if ! kubectl wait --for=condition=Available deployment/fleet-controller \
            -n "$fleet_ns" --timeout=180s 2>/dev/null; then
            warn "Fleet controller not fully ready, but CRDs are available"
            kubectl -n "$fleet_ns" get pods
        fi
    fi

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

    # Docker Desktop is only required for Mac platform (KIND clusters)
    # When targeting Pi, Docker is not needed on the Mac
    if [[ "$PLATFORM" == mac-* || "$PLATFORM" == mac ]]; then
        if ! check_command docker; then
            echo ""
            error "Docker Desktop is required for KIND clusters."
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
    fi

    # Base packages needed regardless of target platform
    local packages=("kubectl" "helm" "sops" "age" "jq" "yq")

    # Add platform-specific tools
    if [[ "$PLATFORM" == mac-* || "$PLATFORM" == mac ]]; then
        packages+=("kind")
    fi
    if [[ "$PLATFORM" == "pi" ]]; then
        packages+=("ansible")
    fi

    for pkg in "${packages[@]}"; do
        if ! check_command "$pkg"; then
            log "Installing $pkg..."
            brew install "$pkg"
        else
            debug "$pkg already installed"
        fi
    done

    # Install k3sup for remote K3s installation (useful for Pi)
    if [[ "$PLATFORM" == "pi" ]]; then
        if ! check_command k3sup; then
            log "Installing k3sup..."
            brew install k3sup
        fi
    fi

    # Install Karmada + Flux tools if using the karmada stack
    if [[ "$STACK" == "karmada" ]]; then
        if ! check_command karmadactl; then
            log "Installing karmadactl..."
            brew install karmadactl
        else
            debug "karmadactl already installed"
        fi

        if ! check_command flux; then
            log "Installing flux CLI..."
            brew install fluxcd/tap/flux
        else
            debug "flux CLI already installed"
        fi
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

    # Install Karmada + Flux tools if using the karmada stack
    if [[ "$STACK" == "karmada" ]]; then
        if ! check_command karmadactl; then
            log "Installing karmadactl..."
            local karmada_arch
            karmada_arch="$(dpkg --print-architecture)"
            curl -sL "https://github.com/karmada-io/karmada/releases/download/v${KARMADA_VERSION}/karmadactl-linux-${karmada_arch}" -o /tmp/karmadactl
            sudo install -o root -g root -m 0755 /tmp/karmadactl /usr/local/bin/karmadactl
            rm -f /tmp/karmadactl
        fi

        if ! check_command flux; then
            log "Installing flux CLI..."
            curl -s https://fluxcd.io/install.sh | bash
        fi
    fi
}

preflight_checks() {
    log "Running preflight checks..."
    local checks_passed=true

    # Check for required tools based on platform + stack
    log "Checking required tools..."
    local required_tools=()
    local optional_tools=()

    case "$PLATFORM" in
        mac|mac-*)
            required_tools=("docker" "kubectl" "helm" "kind")
            optional_tools=("yq" "jq" "ansible")
            ;;
        pi|linux-*)
            # When running from Mac targeting Pi, we need SSH + ansible
            if [[ "$HOST_OS" == "darwin" ]]; then
                required_tools=("kubectl" "helm" "ssh" "ansible")
            else
                required_tools=("kubectl" "helm")
            fi
            optional_tools=("yq" "jq" "curl")
            ;;
        cloud)
            required_tools=("kubectl" "helm" "terraform")
            optional_tools=("yq" "jq" "aws" "gcloud" "az")
            ;;
    esac

    # Add stack-specific tools
    if [[ "$STACK" == "karmada" ]]; then
        required_tools+=("karmadactl" "flux")
    fi

    local missing_required=()
    local missing_optional=()

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_required+=("$tool")
        else
            debug "  ✓ $tool found"
        fi
    done

    for tool in "${optional_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            missing_optional+=("$tool")
        else
            debug "  ✓ $tool found (optional)"
        fi
    done

    if [[ ${#missing_required[@]} -gt 0 ]]; then
        if [[ "$SKIP_PREREQS" == "true" ]]; then
            error "Required tools missing: ${missing_required[*]}"
            error "Cannot continue with --skip-prereqs when required tools are missing"
            checks_passed=false
        else
            warn "Required tools missing: ${missing_required[*]}"
            log "These will be installed during prerequisite setup"
        fi
    fi

    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        debug "Optional tools missing (will be installed): ${missing_optional[*]}"
    fi

    # Check disk space (need at least 10GB)
    local free_space
    if [[ "$HOST_OS" == "darwin" ]]; then
        free_space=$(df -g / | awk 'NR==2 {print $4}')
    else
        if df -BG / &>/dev/null; then
            free_space=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
        else
            free_space=$(df -k / | awk 'NR==2 {print int($4/1024/1024)}')
        fi
    fi

    if [[ -n "$free_space" ]] && [[ "$free_space" -lt 10 ]]; then
        warn "Low disk space: ${free_space}GB available (10GB recommended)"
    fi

    # Check Docker Desktop memory allocation (only for Mac platform with KIND)
    if [[ "$PLATFORM" == mac-* ]] && check_command docker; then
        local docker_memory_gb
        docker_memory_gb=$(docker system info 2>/dev/null | grep "Total Memory" | awk '{print int($3)}')
        if [[ -n "$docker_memory_gb" ]] && [[ "$docker_memory_gb" -lt 10 ]]; then
            echo ""
            warn "Docker Desktop has only ${docker_memory_gb}GB RAM allocated."
            warn "Rancher + KIND needs at least 10GB RAM for reliable operation."
            warn ""
            warn "To increase Docker memory:"
            warn "  1. Open Docker Desktop -> Settings -> Resources"
            warn "  2. Increase Memory to 10GB or more"
            warn "  3. Click 'Apply & Restart'"
            warn ""
            if [[ "${FORCE_LOW_MEMORY:-}" != "true" ]]; then
                read -p "Continue anyway? (may cause Rancher pods to fail) [y/N] " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    error "Aborted. Please increase Docker memory and retry."
                    exit 1
                fi
            fi
        else
            debug "Docker memory: ${docker_memory_gb}GB ✓"
        fi
    fi

    # Check network connectivity
    if ! curl -s --connect-timeout 5 https://github.com > /dev/null; then
        error "Cannot reach GitHub. Check network connectivity."
        checks_passed=false
    fi

    # Check for existing clusters (if not cleanup mode)
    if [[ "$CLEANUP" != "true" ]] && check_command kubectl; then
        if kubectl cluster-info --request-timeout=5s &>/dev/null; then
            warn "Existing Kubernetes cluster detected. Use --cleanup to remove first."
        fi
    fi

    # Pi-specific checks (only when running ON the Pi, not remotely from Mac)
    if [[ "$PLATFORM" == "pi" && "$HOST_OS" == "linux" ]]; then
        if ! grep -q "cgroup_memory=1" /proc/cmdline 2>/dev/null; then
            warn "cgroup memory not enabled. Required for K3s."
        fi
        if [[ $(swapon --show | wc -l) -gt 0 ]]; then
            warn "Swap is enabled. Should be disabled for Kubernetes."
        fi
    fi

    # When targeting Pi remotely, check SSH connectivity
    if [[ "$PLATFORM" == "pi" && "$HOST_OS" == "darwin" ]]; then
        local inventory="${SCRIPT_DIR}/pi-setup/inventory.ini"
        if [[ -f "$inventory" ]]; then
            local pi_ip
            pi_ip=$(awk '/^\[masters\]/{found=1; next} found && /^[^#\[]/ && NF{print; exit}' "$inventory" | sed 's/.*ansible_host=//' | awk '{print $1}')
            if [[ -n "$pi_ip" && "$pi_ip" != "CHANGE_ME" ]]; then
                log "Checking SSH connectivity to Pi at ${pi_ip}..."
                if ssh -o ConnectTimeout=5 -o BatchMode=yes "admin@${pi_ip}" true 2>/dev/null; then
                    log "SSH to Pi ✓"
                else
                    warn "Cannot SSH to Pi at ${pi_ip}. Ensure:"
                    warn "  1. Pi is powered on and connected via ethernet"
                    warn "  2. SSH key is in ~/.ssh/id_ed25519"
                    warn "  3. Pi is configured with user 'admin'"
                    warn "  4. IP address ${pi_ip} is correct in pi-setup/inventory.ini"
                fi
            elif [[ "$pi_ip" == "CHANGE_ME" ]]; then
                warn "Pi IP not configured in pi-setup/inventory.ini"
                warn "Set ansible_host= to your Pi's ethernet IP before running"
            fi
        else
            warn "Inventory file not found at ${inventory}"
            warn "Update pi-setup/inventory.ini with your Pi's IP address"
        fi
    fi

    if [[ "$checks_passed" != "true" ]]; then
        error "Preflight checks failed"
        exit 1
    fi

    log "Preflight checks passed ✓"
}

cleanup_existing() {
    log "Cleaning up existing installation (stack: ${STACK})..."

    # Stack-specific cleanup
    if [[ "$STACK" == "karmada" ]]; then
        cleanup_karmada
    fi

    case "$PLATFORM" in
        mac-*)
            # Check if KIND cluster exists and clean up Helm releases first
            if kind get clusters 2>/dev/null | grep -q "kube-world"; then
                log "Cleaning up Helm releases..."
                kubectl config use-context kind-kube-world 2>/dev/null || true

                # Uninstall Helm releases in reverse dependency order
                helm uninstall rancher -n cattle-system 2>/dev/null || true
                helm uninstall cert-manager -n cert-manager 2>/dev/null || true

                if [[ "$STACK" == "fleet" ]]; then
                    # Delete Rancher/Fleet namespaces (can take time due to finalizers)
                    log "Deleting Rancher/Fleet namespaces (may take a minute)..."
                    for ns in cattle-system cattle-fleet-system cattle-fleet-local-system fleet-system fleet-local cert-manager; do
                        kubectl delete namespace "$ns" --timeout=60s 2>/dev/null || true
                    done

                    # Remove Fleet CRDs that might have finalizers
                    log "Removing Fleet CRDs..."
                    kubectl get crd -o name 2>/dev/null | grep -E 'fleet|cattle|rancher' | xargs -r kubectl delete --timeout=30s 2>/dev/null || true
                else
                    # Clean up Rancher namespaces (no Fleet)
                    log "Deleting Rancher namespaces (may take a minute)..."
                    for ns in cattle-system cert-manager; do
                        kubectl delete namespace "$ns" --timeout=60s 2>/dev/null || true
                    done
                fi
            fi

            # Delete KIND clusters
            log "Deleting KIND clusters..."
            kind delete cluster --name management 2>/dev/null || true
            kind delete cluster --name kube-world 2>/dev/null || true

            # Clean up any orphaned Docker containers from KIND
            docker ps -a --filter "name=kube-world" -q 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
            docker ps -a --filter "name=management" -q 2>/dev/null | xargs -r docker rm -f 2>/dev/null || true
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

    # Extract Pi IP from inventory (set global PI_IP for use in completion messages)
    PI_IP=$(awk '/^\[masters\]/{found=1; next} found && /^[^#\[]/ && NF{print; exit}' "$inventory" | sed 's/.*ansible_host=//' | awk '{print $1}')

    if [[ -z "$PI_IP" || "$PI_IP" == "CHANGE_ME" ]]; then
        error "Pi IP address not configured in inventory: $inventory"
        error ""
        error "Before running bootstrap, update the ansible_host in pi-setup/inventory.ini:"
        error "  1. Connect Pi via ethernet to your router"
        error "  2. Find its IP:"
        error "     - Router admin page: check DHCP leases"
        error "     - mDNS:  ping raspberrypi.local"
        error "     - nmap:  nmap -sn 192.168.1.0/24 | grep -B2 Raspberry"
        error "     - arp:   arp -a | grep 'dc:a6:32\|d8:3a:dd\|2c:cf:67\|e4:5f:01'"
        error "  3. Edit pi-setup/inventory.ini: set ansible_host=<your-pi-ip>"
        exit 1
    fi

    log "Target Pi: ${PI_IP}"

    if [[ "$HOST_OS" == "darwin" ]]; then
        # Running from Mac — provision Pi remotely via Ansible
        log "Provisioning Pi remotely from Mac via Ansible..."

        if [[ ! -f "$playbook" ]]; then
            error "Ansible playbook not found at $playbook"
            exit 1
        fi

        # Pass Tailscale auth key if available (for headless Tailscale setup)
        local tailscale_args=""
        if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
            tailscale_args="-e tailscale_auth_key=${TAILSCALE_AUTH_KEY}"
        fi
        if [[ -n "${CENTRAL_TAILSCALE_IP:-}" ]]; then
            tailscale_args="${tailscale_args} -e central_tailscale_ip=${CENTRAL_TAILSCALE_IP}"
        fi

        local domain_args=""
        if [[ -n "${DOMAIN:-}" ]]; then
            domain_args="-e domain=${DOMAIN}"
        fi

        ansible-playbook -i "$inventory" "$playbook" \
            -e "k3s_version=${K3S_VERSION}" \
            -e "mode=${MODE}" \
            ${tailscale_args} \
            ${domain_args}

        # Copy kubeconfig from Pi to Mac
        log "Fetching kubeconfig from Pi..."
        mkdir -p "$KUBECONFIG_DIR"

        local retries=5
        local count=0
        while [[ $count -lt $retries ]]; do
            if scp "admin@${PI_IP}:/etc/rancher/k3s/k3s.yaml" "${KUBECONFIG_DIR}/pi-config" 2>/dev/null; then
                break
            fi
            count=$((count + 1))
            log "Waiting for K3s kubeconfig to be available... (${count}/${retries})"
            sleep 10
        done

        if [[ $count -ge $retries ]]; then
            error "Failed to fetch kubeconfig from Pi after ${retries} attempts"
            error "Check: ssh admin@${PI_IP} 'ls -la /etc/rancher/k3s/k3s.yaml'"
            exit 1
        fi

        # Rewrite kubeconfig to point at Pi's IP instead of localhost
        if [[ "$HOST_OS" == "darwin" ]]; then
            sed -i '' "s/127.0.0.1/${PI_IP}/g" "${KUBECONFIG_DIR}/pi-config"
        else
            sed -i "s/127.0.0.1/${PI_IP}/g" "${KUBECONFIG_DIR}/pi-config"
        fi

    else
        # Running directly on the Pi
        log "Provisioning Pi locally..."

        if [[ -f "$playbook" ]]; then
            local tailscale_args=""
            if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
                tailscale_args="-e tailscale_auth_key=${TAILSCALE_AUTH_KEY}"
            fi
            if [[ -n "${CENTRAL_TAILSCALE_IP:-}" ]]; then
                tailscale_args="${tailscale_args} -e central_tailscale_ip=${CENTRAL_TAILSCALE_IP}"
            fi

            local domain_args=""
            if [[ -n "${DOMAIN:-}" ]]; then
                domain_args="-e domain=${DOMAIN}"
            fi

            ansible-playbook -i "$inventory" "$playbook" \
                -e "k3s_version=${K3S_VERSION}" \
                -e "mode=${MODE}" \
                ${tailscale_args} \
                ${domain_args} \
                --connection=local
        fi

        # K3s kubeconfig is local
        mkdir -p "$KUBECONFIG_DIR"
        if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
            cp /etc/rancher/k3s/k3s.yaml "${KUBECONFIG_DIR}/pi-config"
        else
            error "K3s kubeconfig not found at /etc/rancher/k3s/k3s.yaml"
            error "Is K3s installed? Try: curl -sfL https://get.k3s.io | sh -"
            exit 1
        fi
    fi

    export KUBECONFIG="${KUBECONFIG_DIR}/pi-config"

    # Wait for cluster to be ready
    log "Waiting for Pi K3s cluster to be ready..."
    local ready_timeout=120
    local ready_elapsed=0
    while [[ $ready_elapsed -lt $ready_timeout ]]; do
        if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
            break
        fi
        debug "Waiting for K3s node to be Ready... (${ready_elapsed}/${ready_timeout}s)"
        sleep 5
        ready_elapsed=$((ready_elapsed + 5))
    done

    if [[ $ready_elapsed -ge $ready_timeout ]]; then
        error "K3s node not ready after ${ready_timeout}s"
        kubectl get nodes 2>/dev/null || true
        exit 1
    fi

    kubectl get nodes -o wide
    log "Pi cluster setup complete ✓"
    log "KUBECONFIG set to: ${KUBECONFIG}"
}

#===============================================================================
# Rancher Installation
#===============================================================================
install_rancher() {
    log "Installing Rancher..."

    # Export RANCHER_HOSTNAME and RANCHER_TLS_SOURCE BEFORE sourcing so the
    # sourced script's top-level detection logic respects our values
    export RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-}"
    export RANCHER_TLS_SOURCE="${RANCHER_TLS_SOURCE:-}"

    # Source the install script (runs top-level code: hostname detection,
    # password generation, function definitions)
    source "${SCRIPT_DIR}/rancher/install-rancher.sh"

    # Call main() to actually install (sourced script only defines functions)
    main

    # Capture RANCHER_BOOTSTRAP_PASSWORD set by the sourced script so
    # configure_rancher_api() and other post-install functions can use it
    export RANCHER_BOOTSTRAP_PASSWORD="${RANCHER_BOOTSTRAP_PASSWORD}"
}

#===============================================================================
# Configure Rancher API Settings (post-install)
# Sets server-url and agent-tls-mode for Tailscale/LE cert connectivity
#===============================================================================
configure_rancher_api() {
    if [[ "$PLATFORM" != "pi" ]]; then
        debug "Skipping Rancher API config (Pi-only)"
        return 0
    fi

    local rancher_url="https://${RANCHER_HOSTNAME:?RANCHER_HOSTNAME must be set}"
    log "Configuring Rancher API settings..."

    # Wait for Rancher to respond
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        if curl -sk --connect-timeout 3 "${rancher_url}/ping" 2>/dev/null | grep -q "pong"; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 10
    done

    if [[ $attempts -ge 30 ]]; then
        warn "Rancher not responding at ${rancher_url} — skipping API config"
        return 0
    fi

    # Get API token via bootstrap password
    local login_response
    login_response=$(curl -sk "${rancher_url}/v3-public/localProviders/local?action=login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${RANCHER_BOOTSTRAP_PASSWORD}\"}" 2>/dev/null)
    local api_token
    api_token=$(echo "$login_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")

    if [[ -z "$api_token" ]]; then
        warn "Could not authenticate to Rancher API — configure manually"
        return 0
    fi

    # Set server-url to the public hostname
    curl -sk "${rancher_url}/v3/settings/server-url" \
        -H "Authorization: Bearer ${api_token}" \
        -H "Content-Type: application/json" \
        -X PUT -d "{\"value\":\"${rancher_url}\"}" > /dev/null 2>&1
    log "  server-url = ${rancher_url}"

    # Set agent-tls-mode to system-store (required for LE certs via Tailscale)
    curl -sk "${rancher_url}/v3/settings/agent-tls-mode" \
        -H "Authorization: Bearer ${api_token}" \
        -H "Content-Type: application/json" \
        -X PUT -d '{"value":"system-store"}' > /dev/null 2>&1
    log "  agent-tls-mode = system-store"

    # Clear cacerts (not needed with LE + system-store)
    curl -sk "${rancher_url}/v3/settings/cacerts" \
        -H "Authorization: Bearer ${api_token}" \
        -H "Content-Type: application/json" \
        -X PUT -d '{"value":""}' > /dev/null 2>&1
    log "  cacerts cleared"

    # Delete internal CA secrets (not needed with LE)
    kubectl -n cattle-system delete secret tls-rancher-internal-ca tls-rancher-internal --ignore-not-found 2>/dev/null || true

    log "Rancher API configuration complete ✓"
}

#===============================================================================
# Seed kube-world-secrets and deploy Tailscale key management
#===============================================================================
deploy_tailscale_keys() {
    if [[ "$PLATFORM" != "pi" ]]; then
        debug "Skipping Tailscale key deployment (Pi-only)"
        return 0
    fi

    local tailscale_api_token="${TAILSCALE_API_TOKEN:-}"
    if [[ -z "$tailscale_api_token" ]]; then
        warn "TAILSCALE_API_TOKEN not set — skipping key management deployment"
        warn "Set it and re-run, or deploy apps/tailscale-rotate/cronjob.yaml manually"
        return 0
    fi

    log "Seeding kube-world-secrets with Tailscale credentials..."

    # Extract key ID from the token string (tskey-api-<ID>-<secret>)
    local key_id
    key_id=$(echo "$tailscale_api_token" | sed -E 's/tskey-api-([^-]+)-.*/\1/')

    # Create or update kube-world-secrets
    if kubectl get secret kube-world-secrets -n default &>/dev/null; then
        # Patch existing secret
        kubectl patch secret kube-world-secrets -n default -p "{
            \"data\": {
                \"tailscale-api-token\": \"$(echo -n "$tailscale_api_token" | base64)\",
                \"tailscale-api-key-id\": \"$(echo -n "$key_id" | base64)\"
            }
        }" > /dev/null
    else
        kubectl -n default create secret generic kube-world-secrets \
            --from-literal=tailscale-api-token="$tailscale_api_token" \
            --from-literal=tailscale-api-key-id="$key_id"
    fi
    log "  kube-world-secrets seeded with API token"

    # Create initial auth key for provisioning
    log "Creating initial Tailscale auth key..."
    local auth_response
    auth_response=$(curl -sf -u "${tailscale_api_token}:" \
        -X POST "https://api.tailscale.com/api/v2/tailnet/-/keys" \
        -H "Content-Type: application/json" \
        -d '{
            "capabilities": {"devices": {"create": {"reusable": true, "ephemeral": false, "preauthorized": true, "tags": ["tag:edge"]}}},
            "expirySeconds": 7776000,
            "description": "kube-world provisioning"
        }' 2>/dev/null || echo "")

    if [[ -n "$auth_response" ]]; then
        local auth_key auth_key_id
        auth_key=$(echo "$auth_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || echo "")
        auth_key_id=$(echo "$auth_response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
        if [[ -n "$auth_key" ]]; then
            kubectl patch secret kube-world-secrets -n default -p "{
                \"data\": {
                    \"tailscale-auth-key\": \"$(echo -n "$auth_key" | base64)\",
                    \"tailscale-auth-key-id\": \"$(echo -n "$auth_key_id" | base64)\"
                }
            }" > /dev/null
            log "  Auth key created: ${auth_key_id}"
        fi
    else
        warn "Could not create auth key — Tailscale API may be unreachable"
    fi

    # Deploy key management CronJobs
    log "Deploying Tailscale key management CronJobs..."
    if kubectl apply -f "${SCRIPT_DIR}/apps/tailscale-rotate/cronjob.yaml"; then
        log "Tailscale key management deployed ✓"
    else
        warn "Failed to deploy Tailscale key management CronJobs"
        warn "Apply manually: kubectl apply -f apps/tailscale-rotate/cronjob.yaml"
    fi
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
        if ! kubectl apply -f "${SCRIPT_DIR}/gitops/clusters.yaml"; then
            warn "Failed to apply Fleet clusters configuration"
        fi
    fi
    
    log "GitOps setup complete ✓"
}

#===============================================================================
# Karmada Installation (--stack karmada)
#===============================================================================
install_karmada() {
    log "Installing Karmada control plane..."

    if [[ ! -f "${SCRIPT_DIR}/karmada/install-karmada.sh" ]]; then
        error "karmada/install-karmada.sh not found"
        return 1
    fi

    local karmada_args=()
    # Pass the active KUBECONFIG so the script targets the right cluster
    if [[ -n "${KUBECONFIG:-}" ]]; then
        karmada_args+=("--kubeconfig" "${KUBECONFIG}")
    fi
    [[ "$DRY_RUN" == "true" ]] && karmada_args+=("--dry-run")
    [[ "$VERBOSE" == "true" ]] && karmada_args+=("--verbose")

    bash "${SCRIPT_DIR}/karmada/install-karmada.sh" "${karmada_args[@]}"

    log "Karmada control plane installed ✓"
}

#===============================================================================
# Flux GitOps Setup (--stack karmada)
#===============================================================================
setup_flux() {
    log "Setting up Flux GitOps..."

    # Check flux CLI is available
    if ! command -v flux &>/dev/null; then
        error "flux CLI not found. Install with: brew install fluxcd/tap/flux"
        return 1
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would install Flux and apply kustomizations"
        return 0
    fi

    # Check if Flux is already installed
    if kubectl get namespace flux-system &>/dev/null && \
       kubectl -n flux-system get deployment source-controller &>/dev/null; then
        log "Flux is already installed"
    else
        # Install Flux components into the host cluster
        log "Installing Flux components..."
        flux install --namespace=flux-system
    fi

    # Wait for Flux controllers to be ready
    log "Waiting for Flux controllers..."
    kubectl -n flux-system wait --for=condition=Available deployment --all --timeout=120s

    # Apply GitRepository source
    log "Applying Flux GitRepository source..."
    if ! kubectl apply -f "${SCRIPT_DIR}/flux/sources/git-repository.yaml"; then
        error "Failed to apply Flux GitRepository source"
        return 1
    fi

    # Create the Karmada kubeconfig secret so Flux can target the Karmada API
    local karmada_config="${HOME}/.karmada/karmada-apiserver.config"
    if [[ -f "$karmada_config" ]]; then
        log "Creating Karmada kubeconfig secret for Flux..."
        if ! kubectl -n flux-system create secret generic karmada-kubeconfig \
            --from-file=value="${karmada_config}" \
            --dry-run=client -o yaml | kubectl apply -f -; then
            warn "Failed to create Karmada kubeconfig secret for Flux"
            warn "Flux kustomizations targeting Karmada will fail until this is created."
        fi
    else
        warn "Karmada kubeconfig not found at ${karmada_config}"
        warn "Flux kustomizations targeting Karmada will fail until this is created."
        warn "Run karmada/install-karmada.sh first, then re-run bootstrap."
    fi

    # Apply Flux kustomizations in dependency order
    log "Applying Flux kustomizations..."
    local flux_failed=0
    if ! kubectl apply -f "${SCRIPT_DIR}/flux/kustomizations/karmada-policies.yaml"; then
        warn "Failed to apply karmada-policies kustomization"
        flux_failed=1
    fi
    if ! kubectl apply -f "${SCRIPT_DIR}/flux/kustomizations/policies.yaml"; then
        warn "Failed to apply policies kustomization"
        flux_failed=1
    fi
    if ! kubectl apply -f "${SCRIPT_DIR}/flux/kustomizations/apps.yaml"; then
        warn "Failed to apply apps kustomization"
        flux_failed=1
    fi
    if [[ "$flux_failed" -eq 1 ]]; then
        warn "Some Flux kustomizations failed — check: flux get kustomizations -A"
    fi

    # Verify Flux sources and kustomizations
    log "Flux sources:"
    flux get sources git -A 2>/dev/null || true
    log "Flux kustomizations:"
    flux get kustomizations -A 2>/dev/null || true

    log "Flux GitOps setup complete ✓"
}

#===============================================================================
# Traefik Ingress Controller (replaces K3s builtin, adds Gateway API)
#===============================================================================
install_traefik() {
    log "Installing Traefik ingress controller..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would install Gateway API CRDs, Traefik Helm chart, and Gateway resource"
        return 0
    fi

    # Install Gateway API CRDs (required before Traefik can use them)
    log "Installing Gateway API CRDs..."
    if ! kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml; then
        error "Failed to install Gateway API CRDs — network issue or invalid URL"
        return 1
    fi

    # Add Traefik Helm repo
    if ! helm repo add traefik https://traefik.github.io/charts 2>/dev/null; then
        # Repo may already exist — try update anyway
        debug "helm repo add returned non-zero (repo may already exist)"
    fi
    if ! helm repo update; then
        error "Failed to update Helm repos — check network connectivity"
        return 1
    fi

    # Install Traefik with Pi-optimized values
    local traefik_values="${SCRIPT_DIR}/infrastructure/traefik/values.yaml"
    if [[ ! -f "$traefik_values" ]]; then
        error "Traefik values file not found: ${traefik_values}"
        return 1
    fi

    log "Installing Traefik Helm chart..."
    if ! helm upgrade --install traefik traefik/traefik \
        --namespace kube-system \
        -f "$traefik_values" \
        --wait --timeout 5m; then
        error "Traefik Helm install failed"
        return 1
    fi

    # Wait for Traefik pods
    kubectl -n kube-system wait --for=condition=Available deployment/traefik --timeout=120s
    log "Traefik installed ✓"

    # Apply the shared Gateway resource (HTTP + HTTPS listeners)
    log "Applying Gateway resource..."
    if ! kubectl apply -f "${SCRIPT_DIR}/infrastructure/gateway/gateway.yaml"; then
        error "Failed to apply Gateway resource"
        return 1
    fi
    log "Gateway API configured ✓"
}

#===============================================================================
# Secrets Creation (secrets needed before cert-manager and Flux can work)
#===============================================================================
create_secrets() {
    log "Creating required secrets..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would create Cloudflare API token secret"
        return 0
    fi

    # Cloudflare API token — required for cert-manager DNS-01 challenges
    if kubectl -n cert-manager get secret cloudflare-api-token &>/dev/null; then
        log "Cloudflare API token secret already exists"
    elif [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        if ! kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -; then
            warn "Failed to create cert-manager namespace"
        fi
        if ! kubectl create secret generic cloudflare-api-token \
            --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
            -n cert-manager --dry-run=client -o yaml | kubectl apply -f -; then
            error "Failed to create Cloudflare API token secret"
            return 1
        fi
        log "Cloudflare API token secret created ✓"
    else
        warn "CLOUDFLARE_API_TOKEN not set — skipping cert-manager secret"
        warn "Set it via: export CLOUDFLARE_API_TOKEN=<your-token>"
        warn "Then re-run bootstrap or create manually:"
        warn "  kubectl create secret generic cloudflare-api-token \\"
        warn "    --from-literal=api-token=<token> -n cert-manager"
    fi
}

#===============================================================================
# Let's Encrypt Certificate Setup (runs after cert-manager is installed by Rancher)
#===============================================================================
setup_cert_manager_le() {
    log "Configuring Let's Encrypt wildcard certificate..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would apply ClusterIssuer and Certificate for *.${DOMAIN:-<domain>}"
        return 0
    fi

    # Verify cert-manager is running (installed by rancher/install-rancher.sh)
    if ! kubectl -n cert-manager get deployment cert-manager &>/dev/null; then
        warn "cert-manager not found — skipping Let's Encrypt setup"
        return 0
    fi

    # Apply ClusterIssuer (Let's Encrypt + Cloudflare DNS-01)
    local issuer_file="${SCRIPT_DIR}/infrastructure/cert-manager/clusterissuer.yaml"
    if [[ -f "$issuer_file" ]]; then
        local apply_ok=true
        if [[ -n "$DOMAIN" ]]; then
            sed "s/kubew\.dev/${DOMAIN}/g" "$issuer_file" | kubectl apply -f - || apply_ok=false
        else
            kubectl apply -f "$issuer_file" || apply_ok=false
        fi
        if [[ "$apply_ok" == "true" ]]; then
            log "ClusterIssuer applied ✓"
        else
            warn "Failed to apply ClusterIssuer — TLS certs won't be issued"
        fi
    else
        warn "ClusterIssuer file not found: ${issuer_file}"
    fi

    # Apply Certificate (*.<domain> wildcard)
    local cert_file="${SCRIPT_DIR}/infrastructure/cert-manager/certificate.yaml"
    if [[ -f "$cert_file" ]]; then
        local apply_ok=true
        if [[ -n "$DOMAIN" ]]; then
            sed "s/kubew\.dev/${DOMAIN}/g" "$cert_file" | kubectl apply -f - || apply_ok=false
        else
            kubectl apply -f "$cert_file" || apply_ok=false
        fi
        if [[ "$apply_ok" == "true" ]]; then
            log "Wildcard certificate requested ✓"
        else
            warn "Failed to apply Certificate — TLS certs won't be issued"
        fi
    else
        warn "Certificate file not found: ${cert_file}"
    fi

    # Don't wait for cert — DNS propagation can take minutes
    log "Certificate will be issued once DNS-01 challenge completes"
}

#===============================================================================
# HTTPRoute Setup (Rancher, GitLab, and other services)
#===============================================================================
setup_httproutes() {
    log "Applying HTTPRoutes for services..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would apply HTTPRoutes for Rancher, GitLab"
        return 0
    fi

    # Helper: apply a gateway YAML, substituting domain if set
    apply_gateway() {
        local file="$1" label="$2"
        if [[ ! -f "$file" ]]; then
            debug "Gateway file not found: ${file}"
            return
        fi
        local apply_ok=true
        if [[ -n "${DOMAIN:-}" ]]; then
            sed "s/kubew\.dev/${DOMAIN}/g" "$file" | kubectl apply -f - || apply_ok=false
        else
            kubectl apply -f "$file" || apply_ok=false
        fi
        if [[ "$apply_ok" == "true" ]]; then
            log "${label} HTTPRoute applied ✓"
        else
            warn "Failed to apply ${label} HTTPRoute"
        fi
    }

    # Rancher HTTPRoute
    apply_gateway "${SCRIPT_DIR}/rancher/gateway.yaml" "Rancher"

    # GitLab HTTPRoute + Service/Endpoints (native GitLab on host)
    if [[ -f "${SCRIPT_DIR}/apps/gitlab/service.yaml" ]]; then
        kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f - || warn "Failed to create gitlab namespace"
        if kubectl apply -f "${SCRIPT_DIR}/apps/gitlab/service.yaml"; then
            log "GitLab Service/Endpoints applied ✓"
        else
            warn "Failed to apply GitLab Service/Endpoints"
        fi
    fi
    apply_gateway "${SCRIPT_DIR}/apps/gitlab/gateway.yaml" "GitLab"

    kubectl get httproute -A 2>/dev/null || true
}

#===============================================================================
# GitLab Native Installation (runs on Pi host as systemd, not K8s)
#===============================================================================
install_gitlab_native() {
    log "Installing GitLab CE on Pi host..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would install GitLab CE native deb on Pi"
        return 0
    fi

    local gitlab_script="${SCRIPT_DIR}/scripts/install-gitlab.sh"
    if [[ ! -f "$gitlab_script" ]]; then
        warn "GitLab install script not found: ${gitlab_script}"
        return 0
    fi

    # Determine the target host for SSH
    local target_ip="${PI_IP:-}"
    if [[ -z "$target_ip" ]]; then
        warn "PI_IP not set — skipping GitLab native install"
        return 0
    fi

    # Check if GitLab is already installed
    if ssh "admin@${target_ip}" "command -v gitlab-ctl" &>/dev/null 2>&1; then
        log "GitLab already installed on ${target_ip}"
    else
        log "Running GitLab install script on ${target_ip}..."
        bash "$gitlab_script"
    fi

    log "GitLab native install complete ✓"
}

#===============================================================================
# Karmada Stack Cleanup
#===============================================================================
cleanup_karmada() {
    log "Cleaning up Karmada + Flux installation..."

    # For Pi platform, load the Pi kubeconfig if it exists
    if [[ "$PLATFORM" == "pi" && -f "${KUBECONFIG_DIR}/pi-config" ]]; then
        export KUBECONFIG="${KUBECONFIG_DIR}/pi-config"
        log "Using Pi kubeconfig for cleanup: ${KUBECONFIG}"
    fi

    # Remove Flux kustomizations and sources
    if kubectl get namespace flux-system &>/dev/null 2>&1; then
        log "Uninstalling Flux..."
        flux uninstall --silent 2>/dev/null || true
    fi

    # Remove Karmada
    if kubectl get namespace karmada-system &>/dev/null 2>&1; then
        log "Removing Karmada control plane..."
        karmadactl deinit 2>/dev/null || true
    fi

    # Clean Karmada data directory
    if [[ -d "${HOME}/.karmada" ]]; then
        log "Removing Karmada data directory..."
        rm -rf "${HOME}/.karmada"
    fi

    log "Karmada + Flux cleanup complete ✓"
}

#===============================================================================
# Application Deployment
#===============================================================================
deploy_core_apps() {
    log "Deploying core applications..."
    local failed=0

    # Apply base configurations (excluding fleet.yaml which is processed by Fleet)
    # Fleet bundle configs (fleet.yaml) don't have apiVersion/kind - they're Fleet-specific
    for manifest in "${SCRIPT_DIR}"/apps/base/*.yaml; do
        if [[ -f "$manifest" && "$(basename "$manifest")" != "fleet.yaml" ]]; then
            debug "Applying: $manifest"
            if ! kubectl apply -f "$manifest"; then
                warn "Failed to apply: $(basename "$manifest")"
                failed=$((failed + 1))
            fi
        fi
    done

    # Apply platform-specific configurations
    local platform_apps="${SCRIPT_DIR}/apps/${PLATFORM}/"
    if [[ -d "$platform_apps" ]]; then
        for manifest in "${platform_apps}"*.yaml; do
            if [[ -f "$manifest" && "$(basename "$manifest")" != "fleet.yaml" ]]; then
                debug "Applying: $manifest"
                if ! kubectl apply -f "$manifest"; then
                    warn "Failed to apply: $(basename "$manifest")"
                    failed=$((failed + 1))
                fi
            fi
        done
    fi

    if [[ "$failed" -gt 0 ]]; then
        warn "Core apps: ${failed} manifest(s) failed to apply"
    else
        log "Core apps deployed ✓"
    fi
}

#===============================================================================
# Verification
#===============================================================================
verify_installation() {
    log "Verifying installation (stack: ${STACK})..."

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
    kubectl -n cattle-system get pods 2>/dev/null || echo "Rancher not installed"

    if [[ "$STACK" == "karmada" ]]; then
        echo ""
        echo "=============================================="
        echo "TRAEFIK / GATEWAY API"
        echo "=============================================="
        kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik 2>/dev/null || echo "Traefik not installed"
        kubectl get gateway -n kube-system 2>/dev/null || echo "No Gateway resources"
        kubectl get httproute -A 2>/dev/null || echo "No HTTPRoutes"

        echo ""
        echo "=============================================="
        echo "TLS CERTIFICATES"
        echo "=============================================="
        kubectl get certificate -n kube-system 2>/dev/null || echo "No certificates"
        kubectl get clusterissuer 2>/dev/null || echo "No ClusterIssuers"

        echo ""
        echo "=============================================="
        echo "KARMADA STATUS"
        echo "=============================================="
        kubectl -n karmada-system get pods 2>/dev/null || echo "Karmada not installed"

        echo ""
        echo "=============================================="
        echo "KARMADA CLUSTERS"
        echo "=============================================="
        local karmada_config="${HOME}/.karmada/karmada-apiserver.config"
        if [[ -f "$karmada_config" ]]; then
            karmadactl get clusters --kubeconfig="${karmada_config}" 2>/dev/null || echo "No clusters registered"
        else
            echo "Karmada kubeconfig not found"
        fi

        echo ""
        echo "=============================================="
        echo "FLUX STATUS"
        echo "=============================================="
        flux get sources git -A 2>/dev/null || echo "Flux not configured"
        echo ""
        flux get kustomizations -A 2>/dev/null || echo "No kustomizations"
    else
        echo ""
        echo "=============================================="
        echo "FLEET STATUS"
        echo "=============================================="
        kubectl -n fleet-local get gitrepo 2>/dev/null || echo "Fleet not yet configured"
    fi

    log "Verification complete ✓"
}

#===============================================================================
# Main Execution
#===============================================================================
# Valid platform, mode, and stack values
VALID_PLATFORMS=("mac" "mac-arm64" "mac-amd64" "pi" "linux-arm64" "linux-amd64" "cloud" "auto")
VALID_MODES=("dev" "prod")
VALID_STACKS=("karmada" "fleet")

validate_platform() {
    local platform="$1"
    for valid in "${VALID_PLATFORMS[@]}"; do
        if [[ "$platform" == "$valid" ]]; then
            return 0
        fi
    done
    return 1
}

validate_mode() {
    local mode="$1"
    for valid in "${VALID_MODES[@]}"; do
        if [[ "$mode" == "$valid" ]]; then
            return 0
        fi
    done
    return 1
}

validate_stack() {
    local stack="$1"
    for valid in "${VALID_STACKS[@]}"; do
        if [[ "$stack" == "$valid" ]]; then
            return 0
        fi
    done
    return 1
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --platform)
                if [[ -z "${2:-}" ]]; then
                    error "--platform requires a value"
                    exit 1
                fi
                if ! validate_platform "$2"; then
                    error "Invalid platform: $2"
                    error "Valid platforms: ${VALID_PLATFORMS[*]}"
                    exit 1
                fi
                PLATFORM="$2"
                shift 2
                ;;
            --mode)
                if [[ -z "${2:-}" ]]; then
                    error "--mode requires a value"
                    exit 1
                fi
                if ! validate_mode "$2"; then
                    error "Invalid mode: $2"
                    error "Valid modes: ${VALID_MODES[*]}"
                    exit 1
                fi
                MODE="$2"
                shift 2
                ;;
            --stack)
                if [[ -z "${2:-}" ]]; then
                    error "--stack requires a value"
                    exit 1
                fi
                if ! validate_stack "$2"; then
                    error "Invalid stack: $2"
                    error "Valid stacks: ${VALID_STACKS[*]}"
                    exit 1
                fi
                STACK="$2"
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
                echo "                             Valid: ${VALID_PLATFORMS[*]}"
                echo "  --mode <dev|prod>          Deployment mode (default: dev)"
                echo "  --stack <karmada|fleet>     Orchestration stack (default: karmada)"
                echo "                             karmada: Karmada + Flux + Rancher (recommended)"
                echo "                             fleet:   Legacy Fleet + Rancher"
                echo "  --skip-prereqs             Skip prerequisite installation"
                echo "  --dry-run                  Show what would be done"
                echo "  --cleanup                  Tear down existing setup"
                echo "  --verbose                  Enable verbose output"
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                echo "Use --help for usage information"
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
    log "Stack: $STACK"

    # Dry run mode
    if [[ "$DRY_RUN" == "true" ]]; then
        log "DRY RUN MODE - no changes will be made"
        echo "Would execute:"
        echo "  1. Install prerequisites (on ${HOST_OS})"
        echo "  2. Run preflight checks"
        [[ "$CLEANUP" == "true" ]] && echo "  3. Cleanup existing installation"
        if [[ "$PLATFORM" == "pi" && "$HOST_OS" == "darwin" ]]; then
            echo "  4. Provision Pi via Ansible (remote from Mac)"
            echo "     - Install K3s on Pi"
            echo "     - Fetch kubeconfig to Mac"
        else
            echo "  4. Setup ${PLATFORM} cluster"
        fi
        if [[ "$STACK" == "karmada" ]]; then
            echo "  5. Install Traefik + Gateway API"
            echo "  6. Install Karmada control plane"
            echo "  7. Create secrets (Cloudflare API token)"
            echo "  8. Install Rancher (includes cert-manager, TLS=secret for Pi)"
            echo "  9. Configure Rancher API (server-url, agent-tls-mode)"
            echo " 10. Configure Let's Encrypt wildcard cert"
            echo " 11. Setup Flux GitOps"
            echo " 12. Install GitLab CE (native on Pi)"
            echo " 13. Apply HTTPRoutes (Rancher, GitLab)"
            echo " 14. Deploy Tailscale key management CronJobs"
        else
            echo "  5. Install Rancher"
            echo "  6. Setup Fleet GitOps"
            echo "  7. Deploy core apps"
        fi
        echo " 15. Verify installation"
        exit 0
    fi
    
    # Cleanup if requested
    if [[ "$CLEANUP" == "true" ]]; then
        cleanup_existing
    fi
    
    # Install prerequisites based on HOST OS (where this script runs)
    # not the target platform. E.g., Mac targeting Pi still needs Mac prereqs.
    if [[ "$SKIP_PREREQS" != "true" ]]; then
        case "$HOST_OS" in
            darwin)
                install_prereqs_mac
                ;;
            linux)
                install_prereqs_linux
                ;;
        esac
    fi

    # Load versions from config.yaml (now that yq should be installed)
    load_config_versions
    if [[ "$STACK" == "karmada" ]]; then
        log "Using versions - K3s: ${K3S_VERSION}, Rancher: ${RANCHER_VERSION}, Karmada: ${KARMADA_VERSION}, Flux: ${FLUX_VERSION}, Helm: ${HELM_VERSION}"
    else
        log "Using versions - K3s: ${K3S_VERSION}, Rancher: ${RANCHER_VERSION}, Helm: ${HELM_VERSION}"
    fi

    # Run preflight checks
    preflight_checks
    
    # Setup cluster based on platform
    case "$PLATFORM" in
        mac|mac-*)
            setup_mac_cluster || { error "Mac cluster setup failed"; exit 1; }
            ;;
        pi)
            setup_pi_cluster || { error "Pi cluster setup failed"; exit 1; }
            ;;
        *)
            error "Platform $PLATFORM not yet implemented"
            exit 1
            ;;
    esac
    
    # Resolve domain and derived hostnames
    if [[ -z "$DOMAIN" && -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
        DOMAIN=$(yq eval '.dns.domain // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
    fi
    if [[ -n "$DOMAIN" ]]; then
        RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.${DOMAIN}}"
        GITLAB_HOSTNAME="${GITLAB_HOSTNAME:-gitlab.${DOMAIN}}"
        export DOMAIN RANCHER_HOSTNAME GITLAB_HOSTNAME
        log "Domain: ${DOMAIN} (Rancher: ${RANCHER_HOSTNAME}, GitLab: ${GITLAB_HOSTNAME})"
    else
        warn "DOMAIN not set — hostnames will use auto-detected LAN address"
        warn "Set via: export DOMAIN=yourdomain.com  or use scripts/setup.sh"
    fi

    # Stack-specific orchestration
    if [[ "$STACK" == "karmada" ]]; then
        # Pi with Karmada uses cert-manager/Traefik for TLS, not Rancher's built-in
        if [[ "$PLATFORM" == "pi" ]]; then
            export RANCHER_TLS_SOURCE="secret"
            export RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-}"
        fi

        # Karmada stack: full infrastructure pipeline
        # Critical steps abort on failure; optional steps warn and continue
        install_traefik || { error "Traefik install failed — cannot continue"; exit 1; }
        install_karmada || { error "Karmada install failed — cannot continue"; exit 1; }
        create_secrets               # Optional: warns if CLOUDFLARE_API_TOKEN missing
        install_rancher || { error "Rancher install failed — cannot continue"; exit 1; }
        configure_rancher_api        # Best-effort: warns and continues on failure
        setup_cert_manager_le        # Depends on create_secrets; warns if cert not issued
        setup_flux || { error "Flux setup failed — cannot continue"; exit 1; }
        install_gitlab_native        # Optional: warns if install script missing
        setup_httproutes             # Best-effort: applies available routes
        deploy_tailscale_keys        # Optional: warns if TAILSCALE_API_TOKEN missing
    else
        # Legacy Fleet stack: Rancher -> Fleet -> Apps
        install_rancher
        setup_gitops
        deploy_core_apps
    fi

    # Verify installation
    verify_installation

    echo ""
    echo "=============================================="
    echo "  Bootstrap Complete!"
    echo "  Stack: ${STACK}"
    echo "=============================================="
    echo ""
    if [[ "$STACK" == "karmada" ]]; then
        echo "Next steps:"
        echo "  1. Change Rancher admin password"
        if [[ "$PLATFORM" == "pi" ]]; then
            echo "  2. Access Rancher: https://${RANCHER_HOSTNAME:-rancher.<domain>}"
            echo "  3. Access GitLab:  https://${GITLAB_HOSTNAME:-gitlab.<domain>}"
            echo "  4. Register edge Pi with Karmada:"
            echo "     ./karmada/cluster-registration/register-pi.sh --pi-ip <edge-pi-ip>"
            echo "  5. Import edge Pi into Rancher:"
            echo "     RANCHER_TOKEN=<token> ./rancher/import-cluster.sh --name <name> --pi-ip <ip>"
        else
            echo "  2. Register Pi clusters: ./karmada/cluster-registration/register-pi.sh"
        fi
        echo "  6. Monitor Flux sync: flux get kustomizations -A"
        echo "  7. Check Karmada clusters: karmadactl get clusters"
        if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
            echo ""
            echo "  CLOUDFLARE_API_TOKEN was not set — TLS cert not issued"
            echo "    Set it and re-run, or create the secret manually."
        fi
        if [[ -z "${TAILSCALE_API_TOKEN:-}" ]]; then
            echo ""
            echo "  TAILSCALE_API_TOKEN was not set — key management not deployed"
            echo "    Set it and re-run, or deploy apps/tailscale-rotate/cronjob.yaml manually."
        fi
    else
        echo "Next steps:"
        echo "  1. Change Rancher admin password"
        echo "  2. Register additional clusters via Rancher UI"
        echo "  3. Configure secrets in /secrets/ directory"
        echo "  4. Deploy applications via GitOps"
    fi
    echo ""
    echo "Logs saved to: $LOG_FILE"
}

main "$@"