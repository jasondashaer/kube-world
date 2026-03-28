#!/usr/bin/env bash
#===============================================================================
# Rancher Installation Script
# Installs Rancher with cert-manager on a Kubernetes cluster
#
# NETWORK ACCESSIBILITY:
#   For RPi cluster import, Rancher must be accessible from LAN.
#   This script auto-detects Mac's LAN IP and configures accordingly.
#
# USAGE:
#   # Auto-detect LAN IP (recommended)
#   ./install-rancher.sh
#
#   # Explicit hostname
#   RANCHER_HOSTNAME=192.168.1.50 ./install-rancher.sh
#
#   # Use nip.io for DNS resolution
#   RANCHER_HOSTNAME=rancher.192.168.1.50.nip.io ./install-rancher.sh
#
#===============================================================================
set -euo pipefail

# Configuration
RANCHER_VERSION="${RANCHER_VERSION:-2.13.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.14.0}"
RANCHER_REPLICAS="${RANCHER_REPLICAS:-1}"

#===============================================================================
# Auto-detect Mac LAN IP for remote access
#===============================================================================
get_lan_ip() {
    local lan_ip=""

    # Try multiple methods to find LAN IP
    # Method 1: Check for active interface with route
    if command -v route &>/dev/null; then
        local default_if
        default_if=$(route -n get default 2>/dev/null | grep interface | awk '{print $2}' || true)
        if [[ -n "$default_if" ]]; then
            lan_ip=$(ipconfig getifaddr "$default_if" 2>/dev/null || true)
        fi
    fi

    # Method 2: Try common interfaces
    if [[ -z "$lan_ip" ]]; then
        for iface in en0 en1 en8 en9; do
            lan_ip=$(ipconfig getifaddr "$iface" 2>/dev/null || true)
            if [[ -n "$lan_ip" && "$lan_ip" != "127.0.0.1" ]]; then
                break
            fi
        done
    fi

    # Method 3: Parse ifconfig for non-localhost IPv4
    if [[ -z "$lan_ip" ]]; then
        lan_ip=$(ifconfig 2>/dev/null | grep "inet " | grep -v "127.0.0.1" | head -1 | awk '{print $2}' || true)
    fi

    # Fallback to localhost if nothing found
    echo "${lan_ip:-127.0.0.1}"
}

# Determine Rancher hostname
if [[ -z "${RANCHER_HOSTNAME:-}" ]]; then
    DETECTED_LAN_IP=$(get_lan_ip)
    if [[ "$DETECTED_LAN_IP" != "127.0.0.1" ]]; then
        # Use nip.io for automatic DNS resolution to the LAN IP
        RANCHER_HOSTNAME="rancher.${DETECTED_LAN_IP}.nip.io"
        echo ""
        echo "📡 Auto-detected Mac LAN IP: ${DETECTED_LAN_IP}"
        echo "   Using hostname: ${RANCHER_HOSTNAME}"
        echo "   (RPi will be able to reach Rancher at this address)"
        echo ""
    else
        RANCHER_HOSTNAME="localhost"
        echo ""
        echo "⚠️  WARNING: Could not detect LAN IP, using localhost"
        echo "   RPi will NOT be able to connect to Rancher!"
        echo "   Set RANCHER_HOSTNAME to your Mac's LAN IP manually."
        echo ""
    fi
fi

# Store LAN IP for later use (import commands)
RANCHER_LAN_IP="${RANCHER_LAN_IP:-$(get_lan_ip)}"

# Bootstrap password handling - SECURITY WARNING for weak defaults
if [[ -z "${RANCHER_BOOTSTRAP_PASSWORD:-}" ]]; then
    # Generate a secure random password if not provided
    if command -v openssl &>/dev/null; then
        RANCHER_BOOTSTRAP_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=' | head -c 16)
        GENERATED_PASSWORD=true
    else
        # Fallback - warn user about weak default
        RANCHER_BOOTSTRAP_PASSWORD="admin"
        GENERATED_PASSWORD=false
        echo ""
        echo "⚠️  WARNING: Using weak default Rancher password 'admin'"
        echo "   Set RANCHER_BOOTSTRAP_PASSWORD environment variable for production use:"
        echo "   export RANCHER_BOOTSTRAP_PASSWORD=\"\$(openssl rand -base64 16)\""
        echo ""
    fi
else
    GENERATED_PASSWORD=false
    # Warn if user explicitly set weak password
    if [[ "$RANCHER_BOOTSTRAP_PASSWORD" == "admin" || "$RANCHER_BOOTSTRAP_PASSWORD" == "password" || ${#RANCHER_BOOTSTRAP_PASSWORD} -lt 8 ]]; then
        echo ""
        echo "⚠️  WARNING: Weak Rancher bootstrap password detected"
        echo "   Consider using a stronger password for production deployments"
        echo ""
    fi
fi

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
NC='\033[0m'

log() { echo -e "${GREEN}[RANCHER]${NC} $*"; }
warn() { echo -e "${YELLOW}[RANCHER]${NC} $*"; }
debug() { echo -e "${GRAY}[RANCHER]${NC} $*"; }

#===============================================================================
# Add Helm Repositories
#===============================================================================
add_helm_repos() {
    log "Adding Helm repositories..."
    
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable 2>/dev/null || true
    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
    helm repo update
}

#===============================================================================
# Install NGINX Ingress Controller (for KIND clusters)
#===============================================================================
install_ingress_controller() {
    # Check if this is a KIND cluster
    if ! kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "kind"; then
        debug "Not a KIND cluster, skipping ingress controller installation"
        return 0
    fi
    
    log "Installing NGINX Ingress Controller for KIND..."
    
    # Check if already installed
    if helm status ingress-nginx -n ingress-nginx &>/dev/null; then
        log "Ingress controller already installed"
        return 0
    fi
    
    # Create namespace
    kubectl create namespace ingress-nginx --dry-run=client -o yaml | kubectl apply -f -
    
    # Install ingress-nginx with KIND-specific configuration
    helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
        --namespace ingress-nginx \
        --set controller.hostPort.enabled=true \
        --set controller.service.type=NodePort \
        --set controller.watchIngressWithoutClass=true \
        --set controller.nodeSelector."kubernetes\.io/os"=linux \
        --set controller.admissionWebhooks.enabled=false \
        --wait --timeout 5m
    
    # Wait for ingress controller to be ready
    log "Waiting for ingress controller..."
    kubectl wait --for=condition=Available deployment/ingress-nginx-controller \
        -n ingress-nginx --timeout=120s
    
    log "Ingress controller installed ✓"
}

#===============================================================================
# Install cert-manager
#===============================================================================
install_cert_manager() {
    log "Installing cert-manager ${CERT_MANAGER_VERSION}..."
    
    # Create namespace
    kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -
    
    # Check if already installed
    if helm status cert-manager -n cert-manager &>/dev/null; then
        log "cert-manager already installed, upgrading..."
    fi
    
    # Install/upgrade cert-manager
    helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager \
        --version "${CERT_MANAGER_VERSION}" \
        --set installCRDs=true \
        --set prometheus.enabled=true \
        --wait --timeout 5m
    
    # Wait for webhook to be ready
    log "Waiting for cert-manager webhook..."
    kubectl wait --for=condition=Available deployment/cert-manager-webhook \
        -n cert-manager --timeout=120s
    
    log "cert-manager installed ✓"
}

#===============================================================================
# Install Rancher
#===============================================================================
install_rancher() {
    log "Installing Rancher ${RANCHER_VERSION}..."
    
    # Create namespace
    kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f -
    
    # Determine TLS source based on environment
    local tls_source="rancher"  # Self-signed for dev
    local extra_args=""
    
    if [[ "${RANCHER_TLS_SOURCE:-}" == "letsEncrypt" ]]; then
        tls_source="letsEncrypt"
        extra_args="--set letsEncrypt.email=${LETSENCRYPT_EMAIL:-admin@example.com}"
    elif [[ "${RANCHER_TLS_SOURCE:-}" == "secret" ]]; then
        tls_source="secret"
    fi
    
    # Check if already installed
    if helm status rancher -n cattle-system &>/dev/null; then
        log "Rancher already installed, upgrading..."
    fi
    
    # For KIND clusters, we may need to adjust resources for limited environments
    local resource_args=""
    if kubectl get nodes -o jsonpath='{.items[0].metadata.labels}' 2>/dev/null | grep -q "kind"; then
        log "KIND cluster detected - adjusting for local development..."
        # Reduce resource requests for KIND (won't have full cloud resources)
        resource_args="--set resources.requests.memory=256Mi --set resources.requests.cpu=100m"
    fi
    
    # Install/upgrade Rancher
    helm upgrade --install rancher rancher-stable/rancher \
        --namespace cattle-system \
        --version "${RANCHER_VERSION}" \
        --set hostname="${RANCHER_HOSTNAME}" \
        --set replicas="${RANCHER_REPLICAS}" \
        --set bootstrapPassword="${RANCHER_BOOTSTRAP_PASSWORD}" \
        --set ingress.tls.source="${tls_source}" \
        --set global.cattle.psp.enabled=false \
        ${resource_args} \
        ${extra_args} \
        --wait --timeout 10m
    
    log "Rancher Helm install complete ✓"
    
    # Verify pods are actually running
    log "Verifying Rancher pods are running..."
    local verify_timeout=120
    local verify_elapsed=0
    while [[ $verify_elapsed -lt $verify_timeout ]]; do
        local ready_pods
        ready_pods=$(kubectl -n cattle-system get pods -l app=rancher -o jsonpath='{.items[*].status.containerStatuses[*].ready}' 2>/dev/null | tr ' ' '\n' | grep -c "true" || echo "0")
        local total_pods
        total_pods=$(kubectl -n cattle-system get pods -l app=rancher --no-headers 2>/dev/null | wc -l | tr -d ' ')
        
        if [[ "$ready_pods" -gt 0 ]] && [[ "$ready_pods" == "$total_pods" ]]; then
            log "Rancher pods ready: ${ready_pods}/${total_pods} ✓"
            break
        fi
        debug "Waiting for Rancher pods: ${ready_pods}/${total_pods} ready (${verify_elapsed}/${verify_timeout}s)"
        sleep 10
        verify_elapsed=$((verify_elapsed + 10))
    done
    
    if [[ $verify_elapsed -ge $verify_timeout ]]; then
        warn "Some Rancher pods may not be fully ready. Checking status..."
        kubectl -n cattle-system get pods
    fi
    
    log "Rancher installed ✓"
}

#===============================================================================
# Post-Installation Setup
#===============================================================================
post_install() {
    log "Running post-installation setup..."
    
    # Wait for Rancher deployment to be ready
    log "Waiting for Rancher deployment to be ready..."
    kubectl -n cattle-system rollout status deploy/rancher --timeout=300s
    
    # CRITICAL: Wait for Rancher to fully initialize (not just deployment ready)
    log "Waiting for Rancher internal initialization (this may take several minutes)..."
    local init_timeout=300
    local init_elapsed=0
    while [[ $init_elapsed -lt $init_timeout ]]; do
        # Check if Rancher has created the cattle-fleet-system namespace (sign of full initialization)
        if kubectl get namespace cattle-fleet-system &>/dev/null; then
            log "Rancher cattle-fleet-system namespace created ✓"
            
            # Wait for fleet-controller deployment
            if kubectl -n cattle-fleet-system get deployment fleet-controller &>/dev/null; then
                log "Fleet controller deployment found, waiting for readiness..."
                kubectl -n cattle-fleet-system rollout status deploy/fleet-controller --timeout=180s || true
                break
            fi
        fi
        
        # Check for fleet-system as alternative namespace
        if kubectl get namespace fleet-system &>/dev/null; then
            if kubectl -n fleet-system get deployment fleet-controller &>/dev/null; then
                log "Fleet controller deployment found in fleet-system, waiting..."
                kubectl -n fleet-system rollout status deploy/fleet-controller --timeout=180s || true
                break
            fi
        fi
        
        debug "Rancher still initializing... (${init_elapsed}/${init_timeout}s)"
        sleep 15
        init_elapsed=$((init_elapsed + 15))
    done
    
    # Get Rancher URL
    local rancher_url="https://${RANCHER_HOSTNAME}"
    
    # Print access information
    echo ""
    echo "=============================================="
    echo "  Rancher Installation Complete!"
    echo "=============================================="
    echo ""
    echo "  URL: ${rancher_url}"
    if [[ "${GENERATED_PASSWORD:-false}" == "true" ]]; then
        echo ""
        echo "  🔐 AUTO-GENERATED Bootstrap Password:"
        echo "     ${RANCHER_BOOTSTRAP_PASSWORD}"
        echo ""
        echo "  ⚠️  SAVE THIS PASSWORD NOW - it won't be shown again!"
    else
        echo "  Initial Password: ${RANCHER_BOOTSTRAP_PASSWORD}"
    fi
    echo ""
    echo "  IMPORTANT: Change the admin password immediately after login!"
    echo ""
    
    # For local development, provide port-forward instructions
    if [[ "${RANCHER_HOSTNAME}" == "localhost" ]]; then
        echo "  For local access, run:"
        echo "    kubectl -n cattle-system port-forward svc/rancher 8443:443"
        echo "  Then access: https://localhost:8443"
        echo ""
    fi
    
    # Check Fleet installation (comes with Rancher)
    if kubectl get namespace cattle-fleet-system &>/dev/null || kubectl get namespace fleet-system &>/dev/null; then
        log "Fleet (GitOps) namespace is available ✓"
    else
        warn "Fleet namespace not found - Rancher may still be initializing"
    fi

    # Save configuration for import script
    local rancher_info_file="${SCRIPT_DIR}/.rancher-info"
    cat > "$rancher_info_file" << EOF
# Rancher installation info - generated $(date)
RANCHER_URL=https://${RANCHER_HOSTNAME}
RANCHER_LAN_IP=${RANCHER_LAN_IP}
RANCHER_HOSTNAME=${RANCHER_HOSTNAME}
# Note: Password was displayed at install time
EOF
    chmod 600 "$rancher_info_file"
    log "Saved Rancher info to ${rancher_info_file}"

    # Print RPi import instructions
    echo ""
    echo "=============================================="
    echo "  Importing RPi Cluster into Rancher"
    echo "=============================================="
    echo ""
    echo "  1. Open Rancher UI: https://${RANCHER_HOSTNAME}"
    echo ""
    echo "  2. Navigate to: Cluster Management > Import Existing"
    echo ""
    echo "  3. Choose 'Generic' and give it a name (e.g., 'pi-cluster')"
    echo ""
    echo "  4. Copy the registration command shown in Rancher UI"
    echo ""
    echo "  5. On the RPi, run the command with --insecure flag:"
    echo ""
    echo "     # If using self-signed certs (development):"
    echo "     curl --insecure -sfL https://${RANCHER_HOSTNAME}/v3/import/XXXXX.yaml | kubectl apply -f -"
    echo ""
    echo "  Or use the helper script:"
    echo "     ./rancher/import-cluster.sh <registration-url>"
    echo ""
    echo "  TROUBLESHOOTING:"
    echo "  - Verify connectivity: ping ${RANCHER_LAN_IP}"
    echo "  - Test HTTPS: curl -k https://${RANCHER_HOSTNAME}/ping"
    echo "  - Check firewall: Ensure ports 80,443 are open on Mac"
    echo ""
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#===============================================================================
# Main
#===============================================================================
main() {
    log "Starting Rancher installation..."
    
    # Verify cluster access
    if ! kubectl cluster-info &>/dev/null; then
        echo "ERROR: Cannot connect to Kubernetes cluster"
        exit 1
    fi
    
    add_helm_repos
    install_ingress_controller  # Required for KIND clusters
    install_cert_manager
    install_rancher
    post_install
    
    log "Rancher setup complete!"
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi