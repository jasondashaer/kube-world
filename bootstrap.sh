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
        # Read from config.yaml, overwriting the initial defaults set at
        # script load time. Use plain assignment (not ${:-}) so config.yaml
        # values take precedence over the hardcoded fallbacks in lines 50-54.
        local v
        v=$(yq eval '.deployment.versions.k3s // ""' "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$v" ]] && K3S_VERSION="$v"
        v=$(yq eval '.deployment.versions.rancher // ""' "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$v" ]] && RANCHER_VERSION="$v"
        v=$(yq eval '.deployment.versions.helm // ""' "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$v" ]] && HELM_VERSION="$v"
        v=$(yq eval '.deployment.versions.karmada // ""' "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$v" ]] && KARMADA_VERSION="$v"
        v=$(yq eval '.deployment.versions.flux // ""' "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$v" ]] && FLUX_VERSION="$v"
    fi
    # If config.yaml wasn't available or yq not installed, the defaults
    # from lines 50-54 remain in effect.
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
SKIP_ANSIBLE=false
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
                if ssh -o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "admin@${pi_ip}" true 2>/dev/null; then
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

#===============================================================================
# Ensure we have a Tailscale auth key before provisioning Pis.
#
# Chicken-and-egg: Ansible needs the auth key to `tailscale up --authkey=...`
# the Pi nodes, but the cluster-side key rotation CronJobs that normally
# mint keys don't run until after the cluster exists. This function fills
# that gap by creating a temporary bootstrap key via the Tailscale API
# if TAILSCALE_API_TOKEN is set and TAILSCALE_AUTH_KEY is empty.
# The cluster-side rotation job will replace it with a tag-scoped one later.
#===============================================================================
ensure_tailscale_auth_key() {
    if [[ -n "${TAILSCALE_AUTH_KEY:-}" ]]; then
        debug "TAILSCALE_AUTH_KEY already set — skipping auto-create"
        return 0
    fi

    if [[ -z "${TAILSCALE_API_TOKEN:-}" ]]; then
        warn "Neither TAILSCALE_AUTH_KEY nor TAILSCALE_API_TOKEN set"
        warn "Tailscale will not be authenticated on the Pi nodes"
        return 0
    fi

    log "Creating bootstrap Tailscale auth key via API..."
    local response
    response=$(curl -s -u "${TAILSCALE_API_TOKEN}:" \
        -X POST "https://api.tailscale.com/api/v2/tailnet/-/keys" \
        -H "Content-Type: application/json" \
        -d '{
            "capabilities": {
                "devices": {
                    "create": {
                        "reusable": true,
                        "ephemeral": false,
                        "preauthorized": true,
                        "tags": ["tag:edge"]
                    }
                }
            },
            "expirySeconds": 3600,
            "description": "kube-world-bootstrap"
        }' 2>/dev/null || echo "")

    local new_key
    new_key=$(echo "$response" | jq -r '.key // empty' 2>/dev/null || echo "")

    if [[ -z "$new_key" ]]; then
        warn "Failed to create Tailscale auth key — Pis will not join the tailnet"
        warn "Response: $(echo "$response" | head -c 200)"
        return 0
    fi

    export TAILSCALE_AUTH_KEY="$new_key"
    log "Bootstrap auth key created (reusable, tag:edge, 1h expiry)"
}

#===============================================================================
# Fetch Tailscale MagicDNS suffix via API.
#
# Sets TAILNET_DNS_SUFFIX to the tailnet's DNS name (e.g., tailab53c1.ts.net)
# so that cloudflare_ensure_cnames can build CNAME targets like
# pi-central.<suffix>. The suffix is stable across wipes — it's tied to
# your Tailscale account, not to any specific device.
#===============================================================================
tailscale_fetch_tailnet_suffix() {
    if [[ -n "${TAILNET_DNS_SUFFIX:-}" ]]; then
        debug "TAILNET_DNS_SUFFIX already set: ${TAILNET_DNS_SUFFIX}"
        return 0
    fi
    if [[ -z "${TAILSCALE_API_TOKEN:-}" ]]; then
        debug "TAILSCALE_API_TOKEN not set — cannot fetch tailnet suffix"
        return 0
    fi

    # Pull the suffix from any existing device's DNSName. All devices in
    # a tailnet share the same suffix so the first one works.
    local suffix
    suffix=$(curl -s -u "${TAILSCALE_API_TOKEN}:" \
        "https://api.tailscale.com/api/v2/tailnet/-/devices" 2>/dev/null \
        | jq -r '.devices[0].name // empty' 2>/dev/null \
        | sed -E 's|^[^.]+\.||; s|\.$||' || true)

    if [[ -n "$suffix" && "$suffix" == *.ts.net ]]; then
        export TAILNET_DNS_SUFFIX="$suffix"
        log "Detected Tailscale DNS suffix: ${TAILNET_DNS_SUFFIX}"
    else
        warn "Could not determine Tailscale DNS suffix from API"
    fi
}

#===============================================================================
# Prune stale Tailscale devices matching our Pi hostnames.
#
# When a Pi is wiped and re-joins the tailnet with hostname "pi-central",
# if an OLD "pi-central" device still exists from a previous wipe cycle,
# Tailscale gives the new device a numeric suffix (pi-central-1, -2, …).
# The suffix is baked into its MagicDNS name, which means our CNAME
# records (pointing at pi-central.<suffix>) stop resolving.
#
# Fix: delete any existing devices with the same hostnames before the
# new Pi authenticates. The most-recently-seen device per hostname is
# KEPT (so re-runs on a live cluster don't delete the current nodes);
# everything else gets pruned.
#
# Also reclaims the canonical MagicDNS name via a post-delete rename
# in case Tailscale's sticky naming left a suffix on the kept device.
#===============================================================================
tailscale_prune_stale_devices() {
    if [[ -z "${TAILSCALE_API_TOKEN:-}" ]]; then
        debug "TAILSCALE_API_TOKEN not set — skipping device prune"
        return 0
    fi

    log "Pruning stale Tailscale devices with pi-* hostnames..."

    local ts_api="https://api.tailscale.com/api/v2"
    local all
    all=$(curl -s -u "${TAILSCALE_API_TOKEN}:" "${ts_api}/tailnet/-/devices" 2>/dev/null)
    if [[ -z "$all" ]] || ! echo "$all" | jq -e '.devices' >/dev/null 2>&1; then
        warn "Could not list Tailscale devices — skipping prune"
        return 0
    fi

    # Only prune OFFLINE pi-* devices. Online devices are actively running
    # and should not be deleted (e.g., when re-running bootstrap on a
    # running cluster or after moving Pis to a new network).
    # Duplicate hostnames (e.g., pi-central and pi-central-2) where the
    # primary is online but a stale duplicate exists are also pruned.
    local to_delete
    to_delete=$(echo "$all" | jq -r '
        [.devices[] | select(.hostname | startswith("pi-")) | select(.online == false)]
        | .[] | "\(.nodeId) \(.hostname) \(.addresses[0])"
    ')

    local count=0
    if [[ -n "$to_delete" ]]; then
        while IFS=' ' read -r id hostname ip; do
            [[ -z "$id" ]] && continue
            local http_code
            http_code=$(curl -s -w "%{http_code}" -u "${TAILSCALE_API_TOKEN}:" \
                -X DELETE "${ts_api}/device/${id}" -o /dev/null 2>/dev/null)
            if [[ "$http_code" == "200" ]]; then
                debug "  deleted ${hostname} (${id}, was ${ip})"
                count=$((count + 1))
            else
                warn "  failed to delete ${hostname} (${id}): HTTP ${http_code}"
            fi
        done <<< "$to_delete"
    fi
    log "Pruned ${count} pi-* device(s) — Ansible will re-register fresh ones"
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
        if [[ "$SKIP_ANSIBLE" == "true" ]]; then
            log "Skipping Ansible (--skip-ansible). Fetching kubeconfig only..."
            mkdir -p "$KUBECONFIG_DIR"
            if scp -o StrictHostKeyChecking=accept-new "admin@${PI_IP}:/etc/rancher/k3s/k3s.yaml" "${KUBECONFIG_DIR}/pi-config" 2>/dev/null; then
                if [[ "$HOST_OS" == "darwin" ]]; then
                    sed -i '' "s/127.0.0.1/${PI_IP}/g" "${KUBECONFIG_DIR}/pi-config"
                else
                    sed -i "s/127.0.0.1/${PI_IP}/g" "${KUBECONFIG_DIR}/pi-config"
                fi
                export KUBECONFIG="${KUBECONFIG_DIR}/pi-config"
                log "Kubeconfig fetched ✓"
            else
                error "Could not fetch kubeconfig from ${PI_IP}"
                exit 1
            fi
            return 0
        fi

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

        # Pironman 5 case integration (opt-in via env vars).
        # WITH_PIRONMAN=1 enables OLED + fan controller install.
        # WITH_PIRONMAN_RGB_MONITOR=1 also installs the kube-world
        # metric-driven RGB monitor service (CPU/RAM/temp/k8s-health
        # mapped to case LEDs). Requires WITH_PIRONMAN=1.
        local pironman_args=""
        if [[ "${WITH_PIRONMAN:-0}" == "1" ]]; then
            pironman_args="-e install_pironman=true"
            if [[ "${WITH_PIRONMAN_RGB_MONITOR:-0}" == "1" ]]; then
                pironman_args="${pironman_args} -e install_pironman_rgb_monitor=true"
            fi
        fi

        ANSIBLE_CONFIG="${SCRIPT_DIR}/pi-setup/ansible/ansible.cfg" \
        ansible-playbook -i "$inventory" "$playbook" \
            -e "k3s_version=${K3S_VERSION}" \
            -e "mode=${MODE}" \
            ${tailscale_args} \
            ${domain_args} \
            ${pironman_args}

        # Copy kubeconfig from Pi to Mac
        log "Fetching kubeconfig from Pi..."
        mkdir -p "$KUBECONFIG_DIR"

        local retries=5
        local count=0
        while [[ $count -lt $retries ]]; do
            if scp -o StrictHostKeyChecking=accept-new "admin@${PI_IP}:/etc/rancher/k3s/k3s.yaml" "${KUBECONFIG_DIR}/pi-config" 2>/dev/null; then
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

            local pironman_args=""
            if [[ "${WITH_PIRONMAN:-0}" == "1" ]]; then
                pironman_args="-e install_pironman=true"
                if [[ "${WITH_PIRONMAN_RGB_MONITOR:-0}" == "1" ]]; then
                    pironman_args="${pironman_args} -e install_pironman_rgb_monitor=true"
                fi
            fi

            ANSIBLE_CONFIG="${SCRIPT_DIR}/pi-setup/ansible/ansible.cfg" \
            ansible-playbook -i "$inventory" "$playbook" \
                -e "k3s_version=${K3S_VERSION}" \
                -e "mode=${MODE}" \
                ${tailscale_args} \
                ${domain_args} \
                ${pironman_args} \
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
# Rancher API access helpers — use kubectl port-forward to hit Rancher
# directly via the K8s API server, bypassing DNS/Tailscale/Traefik/svclb.
#
# WHY port-forward instead of the public URL: post-install, the external
# URL (https://rancher.${DOMAIN}) has MANY dependencies that can all fail
# independently — DNS propagation, Tailscale device sync on the operator
# machine, Traefik HTTPRoute reload, svclb readiness, TLS cert, Rancher
# pod internal init. Every dependency is a failure mode that's hard to
# diagnose from bootstrap. Port-forward only depends on:
#   1. kubectl + kubeconfig (which we already have)
#   2. Rancher Service having Endpoints (guaranteed by install_rancher
#      completing its --wait)
# That's it. No network, no DNS, no TLS, no routing.
#===============================================================================

# Start kubectl port-forward to svc/rancher in cattle-system.
# Sets RANCHER_PF_PORT, RANCHER_PF_PID, RANCHER_PF_URL.
# Returns 0 on success (port is listening), 1 on failure.
_rancher_pf_start() {
    unset RANCHER_PF_PORT RANCHER_PF_PID RANCHER_PF_URL

    # Find a free local port starting at 18443
    local port=18443
    while lsof -iTCP:${port} -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; do
        port=$((port + 1))
        if [[ $port -gt 18500 ]]; then
            warn "Could not find free port for Rancher port-forward"
            return 1
        fi
    done

    local pf_log="/tmp/kube-world-rancher-pf-$$.log"
    kubectl -n cattle-system port-forward svc/rancher ${port}:443 \
        > "$pf_log" 2>&1 &
    local pid=$!

    # Wait for the port to start listening
    local waited=0
    while [[ $waited -lt 30 ]]; do
        if lsof -iTCP:${port} -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; then
            export RANCHER_PF_PORT=$port
            export RANCHER_PF_PID=$pid
            export RANCHER_PF_URL="https://localhost:${port}"
            debug "port-forward ready: svc/rancher:443 → localhost:${port} (pid ${pid})"
            return 0
        fi
        # If the process died, bail early with the log
        if ! kill -0 "$pid" 2>/dev/null; then
            error "kubectl port-forward died unexpectedly. Log:"
            cat "$pf_log" >&2 2>/dev/null || true
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done

    warn "kubectl port-forward did not start listening within 30s. Log:"
    cat "$pf_log" >&2 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    return 1
}

# Stop the Rancher port-forward started by _rancher_pf_start.
_rancher_pf_stop() {
    if [[ -n "${RANCHER_PF_PID:-}" ]]; then
        kill "${RANCHER_PF_PID}" 2>/dev/null || true
        wait "${RANCHER_PF_PID}" 2>/dev/null || true
        debug "port-forward stopped (pid ${RANCHER_PF_PID})"
    fi
    rm -f "/tmp/kube-world-rancher-pf-$$.log" 2>/dev/null || true
    unset RANCHER_PF_PORT RANCHER_PF_PID RANCHER_PF_URL
}

# Wait for Rancher API to respond with "pong" at the given base URL.
# Returns 0 once ready, 1 on timeout. Logs verbosely on each failure so
# we can actually diagnose issues instead of silently retrying.
_rancher_wait_ready() {
    local base_url="$1"
    local timeout="${2:-300}"
    local interval=5
    local elapsed=0

    log "Waiting for Rancher API at ${base_url}..."
    while [[ $elapsed -lt $timeout ]]; do
        local response http_code body
        response=$(curl -sk -w "\n__HTTP_CODE__:%{http_code}" \
            --connect-timeout 5 --max-time 10 \
            "${base_url}/ping" 2>&1) || true
        http_code=$(echo "$response" | grep "^__HTTP_CODE__:" | sed 's/__HTTP_CODE__://')
        body=$(echo "$response" | grep -v "^__HTTP_CODE__:")

        if [[ "$http_code" == "200" ]] && [[ "$body" == *"pong"* ]]; then
            log "Rancher API is responding ✓ (HTTP ${http_code}, ${elapsed}s)"
            return 0
        fi

        debug "  [${elapsed}s/${timeout}s] not ready yet: HTTP=${http_code:-none} body='$(echo "${body:0:120}" | tr -d '\n')'"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    error "Rancher API did not become ready after ${timeout}s at ${base_url}"
    error "Last response: HTTP=${http_code:-none}"
    error "Body: $(echo "${body:0:500}" | tr -d '\n')"
    error "Rancher pod state:"
    kubectl -n cattle-system get pods -l app=rancher -o wide >&2 2>/dev/null || true
    return 1
}

#===============================================================================
# Configure Rancher API Settings (post-install)
# Sets server-url and agent-tls-mode for Tailscale/LE cert connectivity.
# Uses port-forward (not external URL) for reliability.
#===============================================================================
configure_rancher_api() {
    if [[ "$PLATFORM" != "pi" ]]; then
        debug "Skipping Rancher API config (Pi-only)"
        return 0
    fi

    if [[ -z "${RANCHER_BOOTSTRAP_PASSWORD:-}" ]]; then
        warn "RANCHER_BOOTSTRAP_PASSWORD not set — skipping API config"
        return 0
    fi

    log "Configuring Rancher API settings (via kubectl port-forward)..."

    if ! _rancher_pf_start; then
        warn "Could not establish port-forward to Rancher — skipping API config"
        return 0
    fi

    # Public URL is what Rancher stores as its server-url so external
    # clients (including cattle-cluster-agent on edge clusters) know
    # where to connect back. The local URL is only for OUR API calls.
    local public_url="https://${RANCHER_HOSTNAME}"
    local local_url="${RANCHER_PF_URL}"

    if ! _rancher_wait_ready "$local_url" 300; then
        _rancher_pf_stop
        warn "Rancher not responding via port-forward — skipping API config"
        return 0
    fi

    # Login to Rancher and mint a session token
    debug "Logging in as admin via port-forward..."
    local login_resp login_code
    login_resp=$(curl -sk -w "\n__HTTP__:%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${RANCHER_BOOTSTRAP_PASSWORD}\",\"responseType\":\"json\"}" \
        "${local_url}/v3-public/localProviders/local?action=login" 2>&1)
    login_code=$(echo "$login_resp" | grep "^__HTTP__:" | sed 's/__HTTP__://')
    login_resp=$(echo "$login_resp" | grep -v "^__HTTP__:")

    local session_token
    session_token=$(echo "$login_resp" | jq -r '.token // empty' 2>/dev/null || true)
    if [[ -z "$session_token" ]]; then
        warn "Rancher login failed (HTTP ${login_code}). Response:"
        warn "  $(echo "${login_resp:0:300}" | tr -d '\n')"
        warn "Check that RANCHER_BOOTSTRAP_PASSWORD matches what Rancher was installed with"
        _rancher_pf_stop
        return 0
    fi
    debug "Logged in, session token obtained"

    # Helper to PUT a Rancher setting
    _cfg_put_setting() {
        local setting="$1" value="$2"
        local resp code
        resp=$(curl -sk -w "\n__HTTP__:%{http_code}" -X PUT \
            -H "Authorization: Bearer ${session_token}" \
            -H "Content-Type: application/json" \
            -d "{\"value\":\"${value}\"}" \
            "${local_url}/v3/settings/${setting}" 2>&1)
        code=$(echo "$resp" | grep "^__HTTP__:" | sed 's/__HTTP__://')
        if [[ "$code" == "200" ]]; then
            log "  ${setting} = ${value}"
        else
            warn "  ${setting}: HTTP ${code} — $(echo "$resp" | grep -v "^__HTTP__:" | head -c 150)"
        fi
    }

    _cfg_put_setting "server-url" "$public_url"
    # agent-tls-mode and cacerts are set via Helm values (--set agentTLSMode
    # and --set privateCA) and become read-only in Rancher 2.13+. Setting
    # them here would return HTTP 405. We only set them via API on older
    # Rancher versions as a fallback — check before attempting.
    local current_atm
    current_atm=$(curl -sk "${local_url}/v3/settings/agent-tls-mode" \
        -H "Authorization: Bearer ${session_token}" 2>/dev/null \
        | jq -r '.value // ""' 2>/dev/null || echo "")
    if [[ "$current_atm" != "system-store" ]]; then
        _cfg_put_setting "agent-tls-mode" "system-store"
    else
        debug "  agent-tls-mode already = system-store (set via Helm)"
    fi

    # Delete internal CA secrets (not needed with LE + system-store)
    kubectl -n cattle-system delete secret tls-rancher-internal-ca tls-rancher-internal \
        --ignore-not-found > /dev/null 2>&1 || true

    _rancher_pf_stop
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
# Edge Cluster Auto-Registration (Karmada + Rancher)
#===============================================================================

# Parse edge cluster entries from inventory.ini. Prints one line per cluster:
#   <name> <ip>
inventory_edge_clusters() {
    local inv="${SCRIPT_DIR}/pi-setup/inventory.ini"
    if [[ ! -f "$inv" ]]; then
        return 0
    fi
    # Read the [edge_clusters] section until the next section or EOF
    awk '
        /^\[edge_clusters\]/ { in_section=1; next }
        /^\[/ { in_section=0 }
        in_section && /^[a-zA-Z]/ && /ansible_host=/ {
            name=$1
            for (i=2; i<=NF; i++) {
                if (match($i, /^ansible_host=/)) {
                    ip=substr($i, 14)
                    print name, ip
                }
            }
        }
    ' "$inv"
}

# Get a Rancher API token by logging in with the bootstrap password.
# Prints the token to stdout, or empty on failure.
rancher_get_api_token() {
    # Uses the caller's existing port-forward (via RANCHER_PF_URL) — caller
    # is responsible for _rancher_pf_start/_rancher_pf_stop. This keeps one
    # port-forward open across multiple API calls instead of spinning one
    # up per call.
    if [[ -z "${RANCHER_PF_URL:-}" ]]; then
        error "rancher_get_api_token called without active port-forward"
        return 1
    fi
    if [[ -z "${RANCHER_BOOTSTRAP_PASSWORD:-}" ]]; then
        error "RANCHER_BOOTSTRAP_PASSWORD not set"
        return 1
    fi

    local login_resp login_code
    login_resp=$(curl -sk -w "\n__HTTP__:%{http_code}" -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${RANCHER_BOOTSTRAP_PASSWORD}\",\"responseType\":\"json\"}" \
        "${RANCHER_PF_URL}/v3-public/localProviders/local?action=login" 2>&1)
    login_code=$(echo "$login_resp" | grep "^__HTTP__:" | sed 's/__HTTP__://')
    login_resp=$(echo "$login_resp" | grep -v "^__HTTP__:")

    local session_token
    session_token=$(echo "$login_resp" | jq -r '.token // empty' 2>/dev/null || true)
    if [[ -z "$session_token" ]]; then
        error "Rancher login failed (HTTP ${login_code}): $(echo "${login_resp:0:200}" | tr -d '\n')"
        return 1
    fi

    # Create a non-expiring API token for long-lived automation
    local token_resp token_code
    token_resp=$(curl -sk -w "\n__HTTP__:%{http_code}" -X POST \
        -H "Authorization: Bearer ${session_token}" \
        -H "Content-Type: application/json" \
        -d '{"type":"token","description":"kube-world bootstrap automation","ttl":0}' \
        "${RANCHER_PF_URL}/v3/token" 2>&1)
    token_code=$(echo "$token_resp" | grep "^__HTTP__:" | sed 's/__HTTP__://')
    token_resp=$(echo "$token_resp" | grep -v "^__HTTP__:")

    local api_token
    api_token=$(echo "$token_resp" | jq -r '.token // empty' 2>/dev/null || true)
    if [[ -z "$api_token" ]]; then
        error "Token creation failed (HTTP ${token_code}): $(echo "${token_resp:0:200}" | tr -d '\n')"
        return 1
    fi
    echo "$api_token"
}

# Auto-import edge clusters from inventory.ini into Rancher.
# Uses port-forward for all API calls (reliable) but passes the PUBLIC
# RANCHER_URL to import-cluster.sh so that the manifest Rancher generates
# for the edge cluster embeds the correct external URL for cattle-agent
# to connect back to.
rancher_import_edge_clusters() {
    if [[ "$PLATFORM" != "pi" ]]; then
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would import edge clusters into Rancher"
        return 0
    fi

    local clusters
    clusters=$(inventory_edge_clusters)
    if [[ -z "$clusters" ]]; then
        debug "No edge clusters found in inventory — skipping Rancher import"
        return 0
    fi

    log "Obtaining Rancher API token (via port-forward)..."
    if ! _rancher_pf_start; then
        warn "Port-forward failed — skipping auto-import"
        warn "Import manually: RANCHER_TOKEN=<token> ./rancher/import-cluster.sh --name <name> --pi-ip <ip>"
        return 0
    fi
    if ! _rancher_wait_ready "$RANCHER_PF_URL" 120; then
        _rancher_pf_stop
        warn "Rancher not responding via port-forward — skipping auto-import"
        return 0
    fi

    local token
    token=$(rancher_get_api_token) || token=""
    if [[ -z "$token" ]]; then
        warn "Could not obtain Rancher API token — skipping auto-import"
        warn "Import manually: RANCHER_TOKEN=<token> ./rancher/import-cluster.sh --name <name> --pi-ip <ip>"
        _rancher_pf_stop
        return 0
    fi
    log "Rancher API token obtained ✓"

    log "Importing edge clusters into Rancher..."
    local name ip
    while IFS=' ' read -r name ip; do
        [[ -z "$name" || -z "$ip" ]] && continue
        log "  Importing ${name} (${ip})..."
        # import-cluster.sh uses RANCHER_URL for its API calls. Pass the
        # port-forward URL so it doesn't depend on external DNS/routing.
        # The server-url Rancher stores internally (set by configure_rancher_api)
        # is the PUBLIC URL — that's what gets baked into the import manifest.
        if ! RANCHER_TOKEN="$token" RANCHER_URL="$RANCHER_PF_URL" \
             DOMAIN="${DOMAIN}" \
             bash "${SCRIPT_DIR}/rancher/import-cluster.sh" --name "$name" --pi-ip "$ip"; then
            warn "Failed to import ${name} into Rancher — continue manually"
        fi
    done <<< "$clusters"

    _rancher_pf_stop
    log "Edge cluster Rancher import complete ✓"
}

# Auto-register edge clusters from inventory.ini with Karmada.
karmada_register_edge_clusters() {
    if [[ "$PLATFORM" != "pi" ]]; then
        return 0
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would register edge clusters with Karmada"
        return 0
    fi

    local clusters
    clusters=$(inventory_edge_clusters)
    if [[ -z "$clusters" ]]; then
        debug "No edge clusters in inventory — skipping Karmada join"
        return 0
    fi

    log "Registering edge clusters with Karmada..."
    local name ip
    while IFS=' ' read -r name ip; do
        [[ -z "$name" || -z "$ip" ]] && continue
        log "  Joining ${name} (${ip})..."
        if ! bash "${SCRIPT_DIR}/karmada/cluster-registration/register-pi.sh" \
             --cluster-name "$name" \
             --cluster-kubeconfig "${HOME}/.kube/${name}-config" \
             --pi-ip "$ip"; then
            warn "Failed to join ${name} to Karmada — continue manually"
        fi
    done <<< "$clusters"

    log "Edge cluster Karmada registration complete ✓"
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
    # Central infrastructure kustomizations (ntfy, renovate)
    for kust in ntfy renovate; do
        local kust_file="${SCRIPT_DIR}/flux/kustomizations/${kust}.yaml"
        if [[ -f "$kust_file" ]]; then
            kubectl apply -f "$kust_file" 2>/dev/null || warn "Failed to apply ${kust} kustomization"
        fi
    done
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

    # Note: Gateway API CRDs are NOT installed here — the Traefik Helm chart
    # ships its own copy in crds/ and installs them on first release. Installing
    # them separately causes field-manager conflicts because Helm and kubectl
    # fight over ownership of the CRD spec.

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
# Cloudflare DNS Management
#===============================================================================

# Look up zone ID for $DOMAIN. Prints zone ID or empty.
cloudflare_get_zone_id() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${DOMAIN:-}" ]]; then
        return 0
    fi
    curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" 2>/dev/null \
        | jq -r '.result[0].id // empty' 2>/dev/null || true
}

# Force a Cloudflare edge DNS cache rebuild by toggling zone settings.
#
# New Cloudflare zones have a known bug where underscore-prefixed TXT
# records (like _acme-challenge.*) don't propagate from the zone API to
# the authoritative nameservers until a zone-level setting change
# triggers an edge rebuild. Without this, cert-manager's DNS-01 challenge
# hangs indefinitely waiting for the TXT record to propagate.
#
# Requires CF API token permissions:
#   - Zone:DNS:Edit (for DNS upsert)
#   - Zone:Zone:Read (for zone ID lookup)
#   - Zone:Zone Settings:Edit (for SSL and dev_mode toggles below)
#
# Observed behavior: a single SSL toggle doesn't always flush the cache;
# pairing SSL toggle with a dev_mode toggle and longer delays is more
# reliable. Safe to run multiple times — idempotent.
cloudflare_force_edge_rebuild() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${DOMAIN:-}" ]]; then
        debug "Skipping CF edge rebuild (no token or domain)"
        return 0
    fi

    local zone_id
    zone_id=$(cloudflare_get_zone_id)
    if [[ -z "$zone_id" ]]; then
        warn "Could not find Cloudflare zone for ${DOMAIN} — skipping edge rebuild"
        return 0
    fi

    log "Forcing Cloudflare edge DNS rebuild (fixes TXT propagation on new zones)..."

    # Helper: PATCH a zone setting. Returns 0 on success, 1 on auth failure.
    _cf_patch_setting() {
        local setting="$1"
        local value="$2"
        local resp
        resp=$(curl -s -X PATCH \
            -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"value\":\"${value}\"}" \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/settings/${setting}" 2>/dev/null)
        echo "$resp" | jq -e '.success == true' >/dev/null 2>&1
    }

    # Snapshot current values so we can restore them
    local current_ssl current_dev_mode
    current_ssl=$(curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/settings/ssl" \
        2>/dev/null | jq -r '.result.value // "full"' 2>/dev/null || echo "full")
    current_dev_mode=$(curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
        "https://api.cloudflare.com/client/v4/zones/${zone_id}/settings/development_mode" \
        2>/dev/null | jq -r '.result.value // "off"' 2>/dev/null || echo "off")

    # Determine alternate SSL value to toggle to
    local other_ssl="full"
    [[ "$current_ssl" == "full" ]] && other_ssl="flexible"

    # Step 1: Toggle SSL to a different value
    if ! _cf_patch_setting "ssl" "$other_ssl"; then
        warn "Cloudflare SSL toggle failed — token lacks 'Zone:Zone Settings:Edit' permission"
        warn "(this is a DIFFERENT permission from 'Zone:SSL and Certificates:Edit')"
        warn ""
        warn "Required CF API token permissions for full bootstrap automation:"
        warn "  - Zone : DNS           : Edit"
        warn "  - Zone : Zone          : Read"
        warn "  - Zone : Zone Settings : Edit   ← this one is for the SSL mode endpoint"
        warn ""
        warn "Manual workaround: toggle SSL mode in the Cloudflare dashboard"
        warn "  https://dash.cloudflare.com → ${DOMAIN} → SSL/TLS → Overview"
        warn "  Change encryption mode (e.g. Full → Flexible → Full)"
        warn ""
        warn "After the toggle, cert-manager will reissue the cert automatically"
        warn "within ~60s. You may need to restart cert-manager + coredns pods"
        warn "to flush DNS negative cache:"
        warn "  kubectl -n cert-manager rollout restart deploy/cert-manager"
        warn "  kubectl -n kube-system rollout restart deploy/coredns"
        return 0
    fi
    sleep 10

    # Step 2: Also toggle development_mode on briefly — additional nudge
    # to the edge rebuild machinery. Best-effort; don't fail if it errors.
    _cf_patch_setting "development_mode" "on" || debug "dev_mode on failed"
    sleep 5

    # Step 3: Restore SSL to original value
    _cf_patch_setting "ssl" "$current_ssl" || warn "Failed to restore SSL to ${current_ssl}"
    sleep 5

    # Step 4: Restore development_mode to original value (should be 'off')
    _cf_patch_setting "development_mode" "$current_dev_mode" || debug "dev_mode restore failed"

    log "Cloudflare edge rebuild triggered ✓ (restored ssl=${current_ssl})"
}

# Create/verify CNAME records for the domain pointing at the central Pi's
# Tailscale MagicDNS name.
#
# Architecture: instead of managing A records with raw Tailscale IPs
# (which drift on wipes, reboots, and auth key rotations), we create
# ONE wildcard CNAME (*.${DOMAIN} → pi-central.<tailnet>.ts.net) and
# one apex CNAME. Tailscale MagicDNS is the dynamic layer — whenever
# the node's IP changes, it's automatically reflected.
#
# Requirements for clients: must be on the tailnet (to resolve .ts.net).
# This is by design — kube-world is a private homelab.
#
# Prerequisites: tailscale_prune_stale_devices must have run so the
# central Pi holds the canonical hostname (not pi-central-N).
cloudflare_ensure_cnames() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${DOMAIN:-}" ]]; then
        debug "Skipping CNAME ensure (no token or domain)"
        return 0
    fi
    if [[ -z "${TAILNET_DNS_SUFFIX:-}" ]]; then
        warn "TAILNET_DNS_SUFFIX not set — cannot create CNAMEs"
        warn "Run tailscale_fetch_tailnet_suffix first"
        return 0
    fi

    local zone_id
    zone_id=$(cloudflare_get_zone_id)
    if [[ -z "$zone_id" ]]; then
        warn "Could not find Cloudflare zone for ${DOMAIN} — skipping CNAME ensure"
        return 0
    fi

    # Target: central Pi's canonical MagicDNS name.
    # Device hostname is fixed in Ansible inventory (pi-central), so
    # this resolves dynamically via Tailscale to whatever IP the node has.
    local target="pi-central.${TAILNET_DNS_SUFFIX}"

    log "Ensuring CNAME records → ${target}..."

    # Two records cover everything:
    #   ${DOMAIN}      — apex (via CF CNAME flattening)
    #   *.${DOMAIN}    — wildcard catches all subdomains automatically
    local names=("${DOMAIN}" "*.${DOMAIN}")

    for name in "${names[@]}"; do
        # Look for any existing record at this name (A or CNAME)
        local existing
        existing=$(curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${name}" \
            2>/dev/null)
        local existing_id existing_type existing_content
        existing_id=$(echo "$existing" | jq -r '.result[0].id // empty' 2>/dev/null || true)
        existing_type=$(echo "$existing" | jq -r '.result[0].type // empty' 2>/dev/null || true)
        existing_content=$(echo "$existing" | jq -r '.result[0].content // empty' 2>/dev/null || true)

        local payload
        payload=$(jq -n --arg name "$name" --arg content "$target" \
            '{type:"CNAME", name:$name, content:$content, ttl:60, proxied:false}')

        if [[ -n "$existing_id" ]]; then
            # Existing record — skip if already correct, otherwise PUT replace.
            if [[ "$existing_type" == "CNAME" && "$existing_content" == "$target" ]]; then
                debug "  ${name}: already correct (CNAME → ${target})"
                continue
            fi
            # Replace (PUT fully overwrites record including type)
            local result
            result=$(curl -s -X PUT \
                -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$payload" \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${existing_id}" \
                2>/dev/null | jq -r '.success' 2>/dev/null || echo "false")
            log "  ${name}: replaced ${existing_type}→CNAME (success=${result})"
        else
            local result
            result=$(curl -s -X POST \
                -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "$payload" \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
                2>/dev/null | jq -r '.success' 2>/dev/null || echo "false")
            log "  ${name}: created CNAME (success=${result})"
        fi
    done

    # Clean up any pre-existing per-service A records that are now redundant
    # because the wildcard covers them. Keeps the Cloudflare dashboard tidy.
    local stale_names=("rancher.${DOMAIN}" "gitlab.${DOMAIN}" "auth.${DOMAIN}" "ha.${DOMAIN}" "ntfy.${DOMAIN}")
    for name in "${stale_names[@]}"; do
        local stale_id
        stale_id=$(curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${name}" \
            2>/dev/null | jq -r '.result[0].id // empty' 2>/dev/null || true)
        if [[ -n "$stale_id" ]]; then
            curl -s -X DELETE -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${stale_id}" \
                > /dev/null 2>&1
            debug "  cleaned stale A record: ${name}"
        fi
    done

    # Per-edge-cluster wildcard CNAMEs: *.edge1.kubew.dev → pi-edge-1.<tailnet>
    # DNS wildcards only match one label, so *.kubew.dev does NOT cover
    # *.edge1.kubew.dev. Each edge cluster needs its own wildcard.
    local clusters
    clusters=$(inventory_edge_clusters)
    if [[ -n "$clusters" ]]; then
        while IFS=' ' read -r cname cip; do
            [[ -z "$cname" ]] && continue
            local subdomain
            subdomain=$(get_edge_subdomain "$cname")
            [[ -z "$subdomain" ]] && continue

            local edge_target="${cname}.${TAILNET_DNS_SUFFIX}"
            local edge_wildcard="*.${subdomain}.${DOMAIN}"

            local existing
            existing=$(curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?name=${edge_wildcard}" \
                2>/dev/null)
            local existing_id existing_content
            existing_id=$(echo "$existing" | jq -r '.result[0].id // empty' 2>/dev/null || true)
            existing_content=$(echo "$existing" | jq -r '.result[0].content // empty' 2>/dev/null || true)

            if [[ -n "$existing_id" && "$existing_content" == "$edge_target" ]]; then
                debug "  ${edge_wildcard}: already correct"
                continue
            fi

            local payload
            payload=$(jq -n --arg name "$edge_wildcard" --arg content "$edge_target" \
                '{type:"CNAME", name:$name, content:$content, ttl:60, proxied:false}')

            if [[ -n "$existing_id" ]]; then
                curl -s -X PUT -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                    -H "Content-Type: application/json" -d "$payload" \
                    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${existing_id}" \
                    > /dev/null 2>&1
                log "  ${edge_wildcard}: updated → ${edge_target}"
            else
                curl -s -X POST -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                    -H "Content-Type: application/json" -d "$payload" \
                    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" \
                    > /dev/null 2>&1
                log "  ${edge_wildcard}: created → ${edge_target}"
            fi
        done <<< "$clusters"
    fi

    log "DNS CNAME records ensured ✓"
}

# Map edge cluster name → subdomain (e.g., pi-edge-1 → edge1).
# Reads from config.yaml if available, falls back to stripping "pi-" prefix.
get_edge_subdomain() {
    local cluster_name="$1"
    if command -v yq &>/dev/null && [[ -f "$CONFIG_FILE" ]]; then
        local sub
        sub=$(yq eval ".karmada.clusters[] | select(.name == \"${cluster_name}\") | .subdomain // \"\"" \
            "$CONFIG_FILE" 2>/dev/null || echo "")
        if [[ -n "$sub" ]]; then
            echo "$sub"
            return
        fi
    fi
    # Fallback: pi-edge-1 → edge1, pi-edge-2 → edge2
    echo "${cluster_name}" | sed 's/^pi-//'
}

#===============================================================================
# Edge Cluster Ingress Stack
#
# Installs Traefik + Gateway API + cert-manager + ExternalDNS on each
# edge cluster so they handle their own traffic directly. Each edge
# cluster gets:
#   - Traefik (hostNetwork, Gateway API provider)
#   - Gateway resource (HTTPS listener with wildcard cert)
#   - cert-manager (Let's Encrypt DNS-01 via Cloudflare)
#   - ExternalDNS (auto-creates Cloudflare records from HTTPRoutes)
#   - Wildcard TLS cert for *.{subdomain}.{domain}
#   - HTTPRoutes for apps deployed to that cluster
#===============================================================================
#===============================================================================
# Edge Cluster Secrets + Kubeconfig for Flux
#
# Flux manages the full edge ingress stack (Traefik, cert-manager,
# ExternalDNS, Gateway, Certificates, HTTPRoutes) via manifests in
# infrastructure/clusters/<edge>/. But Flux needs:
#   1. A kubeconfig secret to reach the edge cluster
#   2. Cloudflare API token secrets on the edge cluster (not in Git)
#   3. A placeholder TLS cert so the Gateway is accepted immediately
#===============================================================================
prepare_edge_for_flux() {
    log "Preparing edge clusters for Flux management..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would create edge kubeconfig + Cloudflare secrets for Flux"
        return 0
    fi

    local clusters
    clusters=$(inventory_edge_clusters)
    if [[ -z "$clusters" ]]; then
        debug "No edge clusters — skipping"
        return 0
    fi

    while IFS=' ' read -r cname cip; do
        [[ -z "$cname" ]] && continue
        local subdomain
        subdomain=$(get_edge_subdomain "$cname")
        local edge_domain="${subdomain}.${DOMAIN}"
        local edge_kubeconfig="${HOME}/.kube/${cname}-config"

        if [[ ! -f "$edge_kubeconfig" ]]; then
            warn "  ${cname}: kubeconfig not found at ${edge_kubeconfig} — skipping"
            continue
        fi

        log "  ${cname}: preparing for Flux (${edge_domain})..."

        # 1. Create kubeconfig secret in flux-system on central cluster
        #    Flux's helm-controller and kustomize-controller use this
        #    to deploy resources to the edge cluster.
        kubectl create secret generic "${cname}-kubeconfig" \
            --namespace flux-system \
            --from-file=value="$edge_kubeconfig" \
            --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
        log "    Kubeconfig secret: ${cname}-kubeconfig in flux-system"

        # 2. Create Cloudflare API token secrets on the edge cluster
        #    (cert-manager and ExternalDNS need these, can't be in Git)
        local SAVE_KUBECONFIG="$KUBECONFIG"
        export KUBECONFIG="$edge_kubeconfig"

        if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
            kubectl create namespace cert-manager 2>/dev/null || true
            kubectl create secret generic cloudflare-api-token \
                --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
                -n cert-manager --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

            kubectl create namespace external-dns 2>/dev/null || true
            kubectl create secret generic cloudflare-api-token \
                --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
                -n external-dns --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
            log "    Cloudflare secrets: cert-manager + external-dns"
        fi

        # 3. Create placeholder TLS cert so Gateway is accepted before
        #    cert-manager issues the real LE cert (~2-5 min)
        if ! kubectl -n kube-system get secret kube-world-tls &>/dev/null; then
            openssl req -x509 -newkey rsa:2048 -keyout /tmp/tls-edge.key \
                -out /tmp/tls-edge.crt -days 1 -nodes \
                -subj "/CN=*.${edge_domain}" \
                -addext "subjectAltName=DNS:*.${edge_domain}" 2>/dev/null
            kubectl -n kube-system create secret tls kube-world-tls \
                --cert=/tmp/tls-edge.crt --key=/tmp/tls-edge.key > /dev/null 2>&1
            rm -f /tmp/tls-edge.key /tmp/tls-edge.crt
            log "    Placeholder TLS cert created"
        fi

        export KUBECONFIG="$SAVE_KUBECONFIG"

        # 4. Apply the Flux Kustomization for this edge cluster's infrastructure
        local flux_kust="${SCRIPT_DIR}/flux/kustomizations/infrastructure-${subdomain}.yaml"
        if [[ -f "$flux_kust" ]]; then
            kubectl apply -f "$flux_kust" 2>/dev/null
            log "    Flux Kustomization applied: infrastructure-${subdomain}"
        else
            warn "    Flux Kustomization not found: ${flux_kust}"
        fi

        log "  ${cname}: ready for Flux ✓"
    done <<< "$clusters"

    log "Edge clusters prepared — Flux will reconcile infrastructure"
}

#===============================================================================
# ExternalDNS on the central cluster for management services.
# Auto-creates Cloudflare records for rancher.kubew.dev, auth.kubew.dev, etc.
#===============================================================================
install_central_external_dns() {
    log "Installing ExternalDNS on central cluster..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would install ExternalDNS on central"
        return 0
    fi

    if helm list -n external-dns 2>/dev/null | grep -q external-dns; then
        log "ExternalDNS already installed on central"
        return 0
    fi

    helm repo add external-dns https://kubernetes-sigs.github.io/external-dns/ 2>/dev/null || true
    helm repo update external-dns 2>/dev/null || true

    kubectl create namespace external-dns 2>/dev/null || true
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        kubectl create secret generic cloudflare-api-token \
            --from-literal=api-token="${CLOUDFLARE_API_TOKEN}" \
            -n external-dns --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
    fi

    # Central manages the root domain but excludes edge subdomains
    local -a helm_args=(
        -n external-dns
        -f "${SCRIPT_DIR}/infrastructure/external-dns/values.yaml"
        --set "domainFilters[0]=${DOMAIN}"
        --set "txtOwnerId=pi-central"
    )
    local clusters idx=0
    clusters=$(inventory_edge_clusters)
    if [[ -n "$clusters" ]]; then
        while IFS=' ' read -r cname cip; do
            [[ -z "$cname" ]] && continue
            local sub
            sub=$(get_edge_subdomain "$cname")
            if [[ -n "$sub" ]]; then
                helm_args+=(--set "excludeDomains[${idx}]=${sub}.${DOMAIN}")
                idx=$((idx + 1))
            fi
        done <<< "$clusters"
    fi

    helm install external-dns external-dns/external-dns \
        "${helm_args[@]}" \
        --wait --timeout 120s 2>&1 | tail -3

    log "ExternalDNS installed on central ✓"
}

# NOTE: fetch_central_tailscale_ip has been removed as of the CNAME/MagicDNS
# architecture. DNS no longer tracks raw Tailscale IPs — all routing goes
# through CNAMEs → pi-central.<tailnet>.ts.net → Tailscale MagicDNS. If
# you're looking for where the Pi's current IP is determined, the answer
# is "it doesn't need to be" — Tailscale handles it dynamically.

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

    # Create a placeholder self-signed TLS cert so the Gateway's HTTPS
    # listener is accepted immediately. Without this, the Gateway is
    # rejected ("secret not found") and NO HTTPRoutes work until the LE
    # cert issues (10-30 min). cert-manager will overwrite this secret
    # with the real LE cert when DNS-01 completes.
    if ! kubectl -n kube-system get secret kube-world-tls &>/dev/null; then
        log "Creating placeholder TLS cert for Gateway..."
        # Must include SANs — Go 1.15+ rejects certs with only CN
        openssl req -x509 -newkey rsa:2048 -keyout /tmp/tls-placeholder.key \
            -out /tmp/tls-placeholder.crt -days 1 -nodes \
            -subj "/CN=*.${DOMAIN:-kubew.dev}" \
            -addext "subjectAltName=DNS:*.${DOMAIN:-kubew.dev},DNS:${DOMAIN:-kubew.dev}" 2>/dev/null
        kubectl -n kube-system create secret tls kube-world-tls \
            --cert=/tmp/tls-placeholder.crt --key=/tmp/tls-placeholder.key \
            > /dev/null 2>&1
        rm -f /tmp/tls-placeholder.key /tmp/tls-placeholder.crt
        log "Placeholder cert created (LE cert will replace it)"
    fi

    # Clean up stale _acme-challenge TXT records from previous bootstrap
    # cycles. cert-manager's cleanup fails silently (empty zone ID bug in
    # its Cloudflare solver), so TXT records accumulate. Having 5+ stale
    # records confuses Let's Encrypt validation. Start each bootstrap with
    # a clean slate.
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${DOMAIN:-}" ]]; then
        local zone_id
        zone_id=$(cloudflare_get_zone_id)
        if [[ -n "$zone_id" ]]; then
            local stale_ids
            stale_ids=$(curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=TXT&name=_acme-challenge.${DOMAIN}" \
                2>/dev/null | jq -r '.result[].id' 2>/dev/null || true)
            local cleaned=0
            if [[ -n "$stale_ids" ]]; then
                while IFS= read -r rid; do
                    [[ -z "$rid" ]] && continue
                    curl -s -X DELETE -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                        "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${rid}" \
                        > /dev/null 2>&1 && cleaned=$((cleaned + 1))
                done <<< "$stale_ids"
            fi
            if [[ $cleaned -gt 0 ]]; then
                log "Cleaned ${cleaned} stale _acme-challenge TXT record(s)"
            fi
        fi
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

    log "Certificate requested — wait_for_cert_ready will poll for issuance"
}

#===============================================================================
# Wait for the wildcard TLS certificate to be Ready.
#
# The cattle-cluster-agent on edge clusters validates TLS when connecting
# to Rancher. If we import before the cert is ready, Traefik serves its
# default self-signed cert and the agent rejects it. This function polls
# the Certificate resource until Ready=True (typically 1-3 min after the
# Cloudflare edge rebuild).
#
# On timeout: logs a warning and continues. The import will still be
# attempted but may fail on TLS (non-blocking).
#===============================================================================
wait_for_cert_ready() {
    if [[ "$DRY_RUN" == "true" ]]; then
        return 0
    fi
    if ! kubectl get certificate -n kube-system kubew-dev-wildcard &>/dev/null; then
        debug "No wildcard certificate found — skipping wait"
        return 0
    fi

    log "Waiting for wildcard TLS certificate to be Ready..."
    local timeout=600  # 10 min — edge rebuild + DNS propagation + LE validation
    local elapsed=0
    local interval=10
    local edge_rebuild_done=false

    while [[ $elapsed -lt $timeout ]]; do
        local ready
        ready=$(kubectl get certificate -n kube-system kubew-dev-wildcard \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$ready" == "True" ]]; then
            log "Wildcard TLS certificate is Ready ✓ (${elapsed}s)"
            return 0
        fi

        # After 30s, cert-manager should have created the ACME challenge TXT
        # record. Trigger the Cloudflare edge rebuild NOW so the TXT propagates.
        # Doing it earlier (before the Certificate exists) doesn't help because
        # the TXT record doesn't exist yet.
        if [[ "$edge_rebuild_done" == "false" && $elapsed -ge 30 ]]; then
            log "  Triggering Cloudflare edge rebuild (TXT record should exist now)..."
            cloudflare_force_edge_rebuild
            edge_rebuild_done=true
        fi

        # Show progress with reason
        local reason
        reason=$(kubectl get certificate -n kube-system kubew-dev-wildcard \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null \
            | head -c 80 || echo "")
        if (( elapsed % 30 == 0 )); then
            debug "  [${elapsed}s/${timeout}s] ${reason}"
        fi

        # At 5 min, check for stuck challenges (stale Cloudflare record IDs
        # cause cert-manager to loop on cleanup errors). Delete stuck challenges
        # and stale TXT records, then delete the order to force a clean retry.
        if [[ $elapsed -eq 300 ]]; then
            local stuck_challenges
            stuck_challenges=$(kubectl get challenges -n kube-system -o name 2>/dev/null || true)
            if [[ -n "$stuck_challenges" ]]; then
                warn "Cert still not ready at 5min — clearing stuck challenges for clean retry"
                kubectl delete challenges -n kube-system --all 2>/dev/null || true
                kubectl delete orders -n kube-system --all 2>/dev/null || true
                # Clean stale TXT records from Cloudflare
                if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${DOMAIN:-}" ]]; then
                    local zone_id
                    zone_id=$(cloudflare_get_zone_id 2>/dev/null || echo "")
                    if [[ -n "$zone_id" ]]; then
                        local stale_ids
                        stale_ids=$(curl -s -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=TXT&name=_acme-challenge.${DOMAIN}" \
                            2>/dev/null | jq -r '.result[].id' 2>/dev/null || true)
                        for rid in $stale_ids; do
                            [[ -z "$rid" ]] && continue
                            curl -s -X DELETE -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
                                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${rid}" \
                                > /dev/null 2>&1
                        done
                    fi
                fi
                # Delete and recreate the certificate to trigger fresh issuance
                kubectl delete certificate -n kube-system kubew-dev-wildcard 2>/dev/null || true
                sleep 3
                local cert_file="${SCRIPT_DIR}/infrastructure/cert-manager/certificate.yaml"
                if [[ -f "$cert_file" ]]; then
                    sed "s/kubew\\.dev/${DOMAIN}/g" "$cert_file" | kubectl apply -f - 2>/dev/null || true
                fi
                log "  Challenges cleared, certificate recreated — retrying"
            fi
        fi

        sleep $interval
        elapsed=$((elapsed + interval))
    done

    warn "TLS certificate not ready after ${timeout}s — continuing anyway"
    warn "Edge cluster import may fail on TLS validation"
    warn "The cert will eventually issue; re-run import afterward:"
    warn "  RANCHER_TOKEN=<token> ./rancher/import-cluster.sh --name <name> --pi-ip <ip>"
    return 0
}

#===============================================================================
# HTTPRoute Setup (Rancher, GitLab, and other services)
#===============================================================================
# Helper to apply a gateway YAML file with optional domain substitution.
# Used by both apply_rancher_httproute and setup_httproutes.
_apply_gateway_file() {
    local file="$1" label="$2"
    if [[ ! -f "$file" ]]; then
        debug "Gateway file not found: ${file}"
        return 0
    fi
    local output
    if [[ -n "${DOMAIN:-}" ]]; then
        output=$(sed "s/kubew\.dev/${DOMAIN}/g" "$file" | kubectl apply -f - 2>&1)
    else
        output=$(kubectl apply -f "$file" 2>&1)
    fi
    if [[ $? -eq 0 ]]; then
        log "${label} HTTPRoute applied ✓"
    else
        warn "Failed to apply ${label} HTTPRoute: ${output}"
    fi
}

# Apply the Rancher HTTPRoute. Called right after install_rancher so that
# Traefik routes traffic to rancher.${DOMAIN} before configure_rancher_api
# or rancher_import_edge_clusters try to reach it via that URL.
apply_rancher_httproute() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would apply Rancher HTTPRoute"
        return 0
    fi
    log "Applying Rancher HTTPRoute..."
    _apply_gateway_file "${SCRIPT_DIR}/rancher/gateway.yaml" "Rancher"
}

setup_httproutes() {
    log "Applying central cluster HTTPRoutes..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would apply central HTTPRoutes"
        return 0
    fi

    # Central cluster routes only — management services that live on pi-central.
    # GitLab HTTPRoute (Service/Endpoints applied by install_gitlab_native).
    # Rancher HTTPRoute applied by apply_rancher_httproute earlier.
    # Zitadel HTTPRoute applied by install_zitadel.
    #
    # Edge app routes (HA, Companion) are managed by Flux via
    # infrastructure/clusters/edge1/raw/httproutes/ — not applied here.
    _apply_gateway_file "${SCRIPT_DIR}/apps/gitlab/gateway.yaml" "GitLab"

    kubectl get httproute -A 2>/dev/null || true
}

#===============================================================================
# GitLab Native Install + Repo Bootstrap
#===============================================================================
# Zitadel Identity Provider (containerized via Helm)
#
# Deploys Zitadel + PostgreSQL via Helm, waits for readiness, then runs
# seed-zitadel.sh to create the org, users, OIDC clients, and roles.
# After seeding, configures Rancher + GitLab to use Zitadel for OIDC.
#===============================================================================
install_zitadel() {
    log "Installing Zitadel identity provider..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would install Zitadel via Helm + seed identity config"
        return 0
    fi

    # Wait for Rancher's validation webhook to be ready before creating
    # any new namespaces. The webhook validates namespace creation and
    # rejects requests during its startup window (~30-90s after Rancher
    # is installed), which can silently break helm install.
    log "  Waiting for Rancher webhook..."
    local webhook_ready=false
    for i in $(seq 1 60); do
        if kubectl -n cattle-system get deploy rancher-webhook -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^[1-9]'; then
            # Additionally verify the webhook endpoints are actually available
            if kubectl -n cattle-system get endpoints rancher-webhook -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q '[0-9]'; then
                webhook_ready=true
                break
            fi
        fi
        sleep 2
    done
    if [[ "$webhook_ready" == "true" ]]; then
        log "  Rancher webhook ready ✓"
    else
        warn "  Rancher webhook not ready after 120s — continuing anyway"
    fi

    # Generate and store the masterkey secret if it doesn't exist
    if ! kubectl -n zitadel get secret zitadel-masterkey &>/dev/null; then
        kubectl create namespace zitadel --dry-run=client -o yaml | kubectl apply -f -
        local masterkey
        # Use openssl instead of tr </dev/urandom — the latter causes SIGPIPE
        # on macOS (head closes pipe → tr gets killed → pipefail exits script)
        masterkey=$(openssl rand -base64 48 | tr -d '/+=\n' | head -c 32)
        kubectl create secret generic zitadel-masterkey \
            --namespace=zitadel \
            --from-literal=masterkey="$masterkey" \
            --dry-run=client -o yaml | kubectl apply -f -
        log "  Masterkey secret created"
    else
        debug "  Masterkey secret already exists"
    fi

    # Add Helm repos
    helm repo add zitadel https://charts.zitadel.com 2>/dev/null || true
    helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
    helm repo update zitadel bitnami > /dev/null 2>&1

    # Install PostgreSQL for Zitadel
    if ! helm status zitadel-postgresql -n zitadel &>/dev/null; then
        log "  Installing PostgreSQL for Zitadel..."
        if ! helm upgrade --install zitadel-postgresql bitnami/postgresql \
            --namespace zitadel --create-namespace \
            --set architecture=standalone \
            --set auth.postgresPassword=zitadel-pg-admin \
            --set auth.username=zitadel \
            --set auth.password=zitadel-pg-password \
            --set auth.database=zitadel \
            --set primary.resources.requests.cpu=50m \
            --set primary.resources.requests.memory=128Mi \
            --set primary.resources.limits.cpu=500m \
            --set primary.resources.limits.memory=256Mi \
            --set primary.persistence.size=2Gi \
            --set primary.persistence.storageClass=local-path \
            --set metrics.enabled=false \
            --wait --timeout 5m; then
            error "PostgreSQL install failed"
            return 1
        fi
    else
        log "  PostgreSQL already installed"
    fi

    # Install Zitadel
    if ! helm status zitadel -n zitadel &>/dev/null; then
        log "  Installing Zitadel..."
        if ! helm upgrade --install zitadel zitadel/zitadel \
            --namespace zitadel \
            --set replicaCount=1 \
            --set resources.requests.cpu=100m \
            --set resources.requests.memory=256Mi \
            --set resources.limits.cpu=1000m \
            --set resources.limits.memory=512Mi \
            --set zitadel.masterkeySecretName=zitadel-masterkey \
            --set zitadel.configmapConfig.ExternalSecure=true \
            --set zitadel.configmapConfig.ExternalDomain="auth.${DOMAIN}" \
            --set zitadel.configmapConfig.ExternalPort=443 \
            --set zitadel.configmapConfig.TLS.Enabled=false \
            --set zitadel.configmapConfig.Database.Postgres.Host=zitadel-postgresql \
            --set zitadel.configmapConfig.Database.Postgres.Port=5432 \
            --set zitadel.configmapConfig.Database.Postgres.Database=zitadel \
            --set zitadel.configmapConfig.Database.Postgres.User.Username=zitadel \
            --set zitadel.configmapConfig.Database.Postgres.User.SSL.Mode=disable \
            --set zitadel.configmapConfig.Database.Postgres.Admin.Username=postgres \
            --set zitadel.configmapConfig.Database.Postgres.Admin.SSL.Mode=disable \
            --set 'zitadel.configmapConfig.FirstInstance.Org.Name=kube-world' \
            --set service.type=ClusterIP \
            --set service.port=8080 \
            --set 'service.annotations.traefik\.ingress\.kubernetes\.io/service\.serversscheme=h2c' \
            --set zitadel.secretConfig.Database.Postgres.User.Password=zitadel-pg-password \
            --set zitadel.secretConfig.Database.Postgres.Admin.Password=zitadel-pg-admin \
            --set login.service.appProtocol="" \
            --wait --timeout 10m; then
            error "Zitadel install failed"
            return 1
        fi
    else
        log "  Zitadel already installed"
    fi

    # Wait for Zitadel to be fully ready (init job + server)
    log "  Waiting for Zitadel to be ready..."
    local timeout=300
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        # Port-forward to check readiness
        local ready
        ready=$(kubectl -n zitadel get pods -l app.kubernetes.io/name=zitadel \
            -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$ready" == "True" ]]; then
            log "  Zitadel is ready ✓"
            break
        fi
        sleep 10
        elapsed=$((elapsed + 10))
        if (( elapsed % 30 == 0 )); then
            debug "  [${elapsed}s] Zitadel not ready yet..."
        fi
    done

    if [[ $elapsed -ge $timeout ]]; then
        warn "Zitadel not ready after ${timeout}s — check pods:"
        kubectl -n zitadel get pods
        return 1
    fi

    # Seed identity configuration
    log "  Seeding Zitadel identity configuration..."
    if ! ADMIN_PASSWORD="${RANCHER_BOOTSTRAP_PASSWORD}" \
         DOMAIN="${DOMAIN}" \
         bash "${SCRIPT_DIR}/scripts/seed-zitadel.sh" --local; then
        warn "Zitadel seed failed — identity can be configured manually"
        warn "Run: ./scripts/seed-zitadel.sh --local"
    fi

    # Apply Zitadel HTTPRoute
    _apply_gateway_file "${SCRIPT_DIR}/apps/zitadel/gateway.yaml" "Zitadel"

    log "Zitadel identity provider installed ✓"
}

#===============================================================================
# Configure Rancher OIDC with Zitadel
#===============================================================================
#===============================================================================
# Patch HA ConfigMap with dynamic Zitadel OIDC client ID.
# The ConfigMap template has HA_OIDC_CLIENT_ID and DOMAIN placeholders.
# After Zitadel seeds, we read the actual client_id from the state file
# and patch the ConfigMap in the Karmada API so it propagates to edge.
#===============================================================================
patch_ha_oidc_client_id() {
    local state_file="/tmp/zitadel-seed.state"
    if [[ ! -f "$state_file" ]]; then
        debug "No Zitadel seed state — skipping HA OIDC patch"
        return 0
    fi

    local ha_client_id
    ha_client_id=$(jq -r '.homeassistant_client_id // empty' "$state_file" 2>/dev/null || echo "")
    if [[ -z "$ha_client_id" ]]; then
        debug "No HA OIDC client ID in seed state — skipping"
        return 0
    fi

    local karmada_config="${HOME}/.karmada/karmada-apiserver.config"
    if [[ ! -f "$karmada_config" ]]; then
        debug "Karmada kubeconfig not found — skipping HA OIDC patch"
        return 0
    fi

    # Read the HA client secret from the Zitadel OIDC secret
    local ha_client_secret
    ha_client_secret=$(jq -r '.homeassistant_client_secret // empty' "$state_file" 2>/dev/null || echo "")
    if [[ -z "$ha_client_secret" ]]; then
        # Try reading from the K8s secret created by seed-zitadel.sh
        ha_client_secret=$(kubectl -n home-assistant get secret zitadel-oidc-homeassistant \
            -o jsonpath='{.data.clientSecret}' 2>/dev/null | base64 -d || echo "")
    fi

    # Local HA credentials for the mobile app (which can't handle OIDC).
    # Defaults to admin user with the Rancher bootstrap password. Can be
    # overridden via HA_LOCAL_USERNAME / HA_LOCAL_PASSWORD env vars.
    local ha_local_username="${HA_LOCAL_USERNAME:-admin}"
    local ha_local_password="${HA_LOCAL_PASSWORD:-${RANCHER_BOOTSTRAP_PASSWORD:-}}"

    log "Creating HA OIDC config secret with client ID: ${ha_client_id}"

    # Create the home-assistant namespace on the Karmada API first
    # (apps-base Flux Kustomization creates it normally, but Flux hasn't
    # synced yet at this point in the bootstrap pipeline).
    kubectl --kubeconfig="$karmada_config" create namespace home-assistant \
        --dry-run=client -o yaml 2>/dev/null | \
        kubectl --kubeconfig="$karmada_config" apply -f - > /dev/null 2>&1 || true

    # Create a Secret in the Karmada API (propagated to edge by the HA
    # PropagationPolicy). The HA init container reads this to patch
    # the configuration.yaml placeholders and seed the local credential.
    local -a secret_args=(
        --from-literal=client-id="${ha_client_id}"
        --from-literal=domain="${DOMAIN}"
        --from-literal=local-username="${ha_local_username}"
    )
    if [[ -n "$ha_client_secret" ]]; then
        secret_args+=(--from-literal=client-secret="${ha_client_secret}")
    fi
    if [[ -n "$ha_local_password" ]]; then
        secret_args+=(--from-literal=local-password="${ha_local_password}")
    fi

    if kubectl --kubeconfig="$karmada_config" -n home-assistant \
        create secret generic ha-oidc-config \
        "${secret_args[@]}" \
        --dry-run=client -o yaml 2>/dev/null | \
        kubectl --kubeconfig="$karmada_config" apply -f - > /dev/null 2>&1; then
        log "HA OIDC config secret created ✓ (local user: ${ha_local_username})"
    else
        warn "HA OIDC config secret creation failed — will retry via Flux"
    fi
    return 0
}

configure_oidc_rancher() {
    log "Configuring Rancher OIDC with Zitadel..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would configure Rancher OIDC"
        return 0
    fi

    # Read OIDC credentials from the state file
    local state_file="/tmp/zitadel-seed.state"
    if [[ ! -f "$state_file" ]]; then
        warn "Zitadel seed state not found — skipping Rancher OIDC config"
        return 0
    fi

    local client_id issuer_url
    client_id=$(jq -r '.rancher_client_id // empty' "$state_file" 2>/dev/null || echo "")
    issuer_url=$(jq -r '.issuer_url // empty' "$state_file" 2>/dev/null || echo "")

    if [[ -z "$client_id" ]]; then
        warn "No Rancher OIDC client ID in seed state — skipping"
        return 0
    fi

    # Read client secret from K8s
    local client_secret
    client_secret=$(kubectl -n cattle-system get secret zitadel-oidc-rancher \
        -o jsonpath='{.data.clientSecret}' 2>/dev/null | base64 -d || echo "")

    if [[ -z "$client_secret" ]]; then
        warn "No Rancher OIDC client secret found — skipping"
        return 0
    fi

    # Configure Rancher's OIDC auth via port-forward API
    if ! _rancher_pf_start; then
        warn "Port-forward to Rancher failed — skipping OIDC config"
        return 0
    fi

    if ! _rancher_wait_ready "$RANCHER_PF_URL" 60; then
        _rancher_pf_stop
        return 0
    fi

    # Login
    local login_resp session_token
    login_resp=$(curl -sk -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${RANCHER_BOOTSTRAP_PASSWORD}\",\"responseType\":\"json\"}" \
        "${RANCHER_PF_URL}/v3-public/localProviders/local?action=login" 2>&1)
    session_token=$(echo "$login_resp" | jq -r '.token // empty' 2>/dev/null || true)

    if [[ -z "$session_token" ]]; then
        warn "Rancher login failed — skipping OIDC config"
        _rancher_pf_stop
        return 0
    fi

    # Configure and enable OIDC entirely via kubectl patch.
    # All endpoint fields must be set explicitly (Rancher's "Specify"
    # endpoints mode). Then we set enabled=true directly — no browser
    # testAndApply step needed.
    kubectl patch authconfig genericoidc --type=merge -p "{
        \"enabled\": true,
        \"clientId\": \"${client_id}\",
        \"clientSecret\": \"${client_secret}\",
        \"issuer\": \"${issuer_url}\",
        \"rancherUrl\": \"https://rancher.${DOMAIN}/dashboard/auth/verify\",
        \"scope\": \"openid profile email\",
        \"authEndpoint\": \"${issuer_url}/oauth/v2/authorize\",
        \"tokenEndpoint\": \"${issuer_url}/oauth/v2/token\",
        \"jwksUrl\": \"${issuer_url}/oauth/v2/keys\",
        \"userInfoEndpoint\": \"${issuer_url}/oidc/v1/userinfo\",
        \"accessMode\": \"unrestricted\"
    }" > /dev/null 2>&1 || warn "  kubectl patch failed"

    _rancher_pf_stop

    log "Rancher OIDC enabled ✓"

    # Map Zitadel groups → Rancher roles
    log "Mapping Zitadel groups to Rancher roles..."
    if bash "${SCRIPT_DIR}/scripts/finalize-oidc.sh" 2>&1; then
        log "Rancher OIDC group mappings complete ✓"
    else
        warn "Group mapping had issues — run ./scripts/finalize-oidc.sh manually"
    fi
}

#===============================================================================
# Installs GitLab CE on the central Pi (systemd), bootstraps the kube-world
# repo inside it, and creates the gitlab-credentials K8s secret that Flux
# uses to pull manifests. This makes Flux + GitOps work out of the box on
# a clean bootstrap without needing to manually install GitLab afterward.
#===============================================================================
install_gitlab_native() {
    log "Installing GitLab CE + bootstrapping repo..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would install GitLab CE, push repo, create deploy token + K8s secret"
        return 0
    fi

    local gitlab_script="${SCRIPT_DIR}/scripts/install-gitlab.sh"
    if [[ ! -f "$gitlab_script" ]]; then
        warn "GitLab install script not found: ${gitlab_script}"
        return 0
    fi

    local target_ip="${PI_IP:-}"
    if [[ -z "$target_ip" ]]; then
        warn "PI_IP not set — skipping GitLab native install"
        return 0
    fi

    # Use Rancher bootstrap password as GitLab root password for operator
    # convenience (one credential to remember during first login).
    local state_file="/tmp/gitlab-bootstrap.state"

    local gitlab_args=(
        --pi-ip "$target_ip"
        --ssh-user "${SSH_USER:-admin}"
        --state-file "$state_file"
        --root-password "${RANCHER_BOOTSTRAP_PASSWORD}"
    )
    if [[ -n "${DOMAIN:-}" ]]; then
        gitlab_args+=(--domain "$DOMAIN")
    fi

    # Pass Zitadel OIDC credentials if available (from seed-zitadel.sh).
    # This enables SSO login on GitLab from first boot.
    local zitadel_state="/tmp/zitadel-seed.state"
    if [[ -f "$zitadel_state" ]]; then
        local gl_client_id gl_client_secret gl_issuer
        gl_client_id=$(jq -r '.gitlab_client_id // empty' "$zitadel_state" 2>/dev/null || echo "")
        gl_issuer=$(jq -r '.issuer_url // empty' "$zitadel_state" 2>/dev/null || echo "")
        # Client secret is in K8s, not the state file
        gl_client_secret=$(kubectl -n zitadel get secret zitadel-oidc-gitlab \
            -o jsonpath='{.data.clientSecret}' 2>/dev/null | base64 -d || echo "")
        if [[ -n "$gl_client_id" && -n "$gl_client_secret" ]]; then
            gitlab_args+=(
                --oidc-client-id "$gl_client_id"
                --oidc-client-secret "$gl_client_secret"
                --oidc-issuer "$gl_issuer"
            )
            log "  OIDC credentials available — GitLab will have SSO from first boot"
        fi
    fi

    log "Running install-gitlab.sh (this takes 10-15 min on first run)..."
    if ! bash "$gitlab_script" "${gitlab_args[@]}"; then
        warn "GitLab install failed — Flux will not be able to sync from GitLab"
        warn "You can retry manually: ${gitlab_script} --pi-ip ${target_ip} --domain ${DOMAIN}"
        return 1
    fi

    if [[ ! -f "$state_file" ]]; then
        warn "GitLab state file not found — cannot create gitlab-credentials secret"
        return 1
    fi

    # Read credentials from state file (produced by install-gitlab.sh)
    local deploy_token deploy_user
    deploy_token=$(jq -r '.deploy_token // empty' "$state_file" 2>/dev/null || echo "")
    deploy_user=$(jq -r '.deploy_token_user // "flux-bootstrap"' "$state_file" 2>/dev/null || echo "flux-bootstrap")

    if [[ -z "$deploy_token" ]]; then
        warn "No deploy token in state file — Flux will not be able to authenticate"
        return 1
    fi

    # Create the gitlab namespace and apply the Service/Endpoints, substituting
    # the central Pi's internal IP for the __PI_IP__ placeholder.
    log "Applying GitLab Service + Endpoints (targeting ${target_ip}:8180)..."
    if ! kubectl create namespace gitlab --dry-run=client -o yaml | kubectl apply -f -; then
        warn "Failed to create gitlab namespace"
        return 1
    fi

    local svc_file="${SCRIPT_DIR}/apps/gitlab/service.yaml"
    if [[ ! -f "$svc_file" ]]; then
        warn "GitLab service manifest not found: ${svc_file}"
        return 1
    fi
    if ! sed "s/__PI_IP__/${target_ip}/g" "$svc_file" | kubectl apply -f -; then
        warn "Failed to apply GitLab Service/Endpoints"
        return 1
    fi

    # Create the gitlab-credentials secret in flux-system so Flux's
    # GitRepository resource can authenticate.
    log "Creating gitlab-credentials secret for Flux..."
    if ! kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -; then
        warn "Failed to create flux-system namespace"
        return 1
    fi
    if ! kubectl create secret generic gitlab-credentials \
        --namespace=flux-system \
        --from-literal=username="$deploy_user" \
        --from-literal=password="$deploy_token" \
        --dry-run=client -o yaml | kubectl apply -f -; then
        warn "Failed to create gitlab-credentials secret"
        return 1
    fi

    # Create the renovate-token secret so the CronJob can authenticate.
    # The deploy token has api+write_repository scope which is sufficient.
    if kubectl create namespace renovate --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1; then
        if kubectl create secret generic renovate-token \
            --namespace=renovate \
            --from-literal=token="$deploy_token" \
            --dry-run=client -o yaml | kubectl apply -f - > /dev/null 2>&1; then
            log "Renovate token secret created ✓"
        else
            warn "Failed to create renovate-token secret"
        fi
    fi

    log "GitLab native install + repo bootstrap complete ✓"
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
            --skip-ansible)
                SKIP_ANSIBLE=true
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
    
    # Pre-provisioning Tailscale setup:
    #   1. Prune stale pi-* devices so new Pis get canonical hostnames
    #      (not pi-central-N with a sticky suffix)
    #   2. Ensure we have a bootstrap auth key for Ansible to register with
    # Both are safe no-ops if TAILSCALE_API_TOKEN is not available.
    if [[ "$PLATFORM" == "pi" ]]; then
        tailscale_prune_stale_devices
        ensure_tailscale_auth_key
    fi

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

        # Ensure Cloudflare CNAMEs point at the central Pi's Tailscale
        # MagicDNS name (stable across wipes). No IP tracking required.
        tailscale_fetch_tailnet_suffix
        cloudflare_ensure_cnames

        # Karmada stack: full infrastructure pipeline
        # Critical steps abort on failure; optional steps warn and continue
        install_traefik || { error "Traefik install failed — cannot continue"; exit 1; }
        install_karmada || { error "Karmada install failed — cannot continue"; exit 1; }
        karmada_register_edge_clusters  # Auto-join edge clusters from inventory
        create_secrets               # Optional: warns if CLOUDFLARE_API_TOKEN missing
        install_rancher || { error "Rancher install failed — cannot continue"; exit 1; }
        # Apply Rancher HTTPRoute BEFORE anything tries to reach it via
        # the external hostname.
        apply_rancher_httproute
        configure_rancher_api        # Best-effort: warns and continues on failure
        # Request the LE wildcard cert early. The DNS-01 challenge + cert
        # issuance runs IN PARALLEL with subsequent steps (Zitadel, GitLab,
        # Flux). By the time we reach rancher_import_edge_clusters at the
        # END of the pipeline, the cert should be ready (~15-20 min later).
        setup_cert_manager_le        # Depends on create_secrets; starts ACME flow
        # Identity provider BEFORE GitLab so GitLab can boot with OIDC
        # config from the start (OIDC client ID/secret baked into gitlab.rb)
        install_zitadel              # Helm install + seed identity config
        patch_ha_oidc_client_id || warn "HA OIDC patch failed — non-critical, continuing"
        configure_oidc_rancher       # Best-effort: Rancher OIDC via port-forward
        # GitLab must come BEFORE Flux — Flux's GitRepository points at the
        # self-hosted GitLab, so the repo and credentials must exist first.
        install_gitlab_native        # Installs CE, pushes repo, creates gitlab-credentials secret
        setup_flux || { error "Flux setup failed — cannot continue"; exit 1; }
        install_central_external_dns || warn "Central ExternalDNS install failed — non-critical, continuing"
        # Import edge clusters LAST — by now the LE cert has had ~20 min
        # to issue (Zitadel + GitLab + Flux all ran while cert-manager
        # was doing the DNS-01 challenge in the background). This avoids
        # the x509 error where cattle-agent gets Traefik's default cert.
        wait_for_cert_ready          # Verify cert is Ready before importing
        rancher_import_edge_clusters # Edge cattle-agent should get valid TLS
        prepare_edge_for_flux || warn "Edge preparation had issues — Flux may need manual reconciliation"
        setup_httproutes             # Central-only routes (GitLab, etc.)
        deploy_tailscale_keys || true  # Optional: warns if TAILSCALE_API_TOKEN missing
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