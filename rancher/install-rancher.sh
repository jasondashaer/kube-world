#!/usr/bin/env bash
#===============================================================================
# Rancher Installation Script
# Installs Rancher with cert-manager on a Kubernetes cluster
#===============================================================================
set -euo pipefail

# Configuration
RANCHER_VERSION="${RANCHER_VERSION:-2.13.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.14.0}"
RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-localhost}"
RANCHER_BOOTSTRAP_PASSWORD="${RANCHER_BOOTSTRAP_PASSWORD:-admin}"
RANCHER_REPLICAS="${RANCHER_REPLICAS:-1}"

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
    helm repo update
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
    
    # Install/upgrade Rancher
    helm upgrade --install rancher rancher-stable/rancher \
        --namespace cattle-system \
        --version "${RANCHER_VERSION}" \
        --set hostname="${RANCHER_HOSTNAME}" \
        --set replicas="${RANCHER_REPLICAS}" \
        --set bootstrapPassword="${RANCHER_BOOTSTRAP_PASSWORD}" \
        --set ingress.tls.source="${tls_source}" \
        --set global.cattle.psp.enabled=false \
        ${extra_args} \
        --wait --timeout 10m
    
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
    echo "  Initial Password: ${RANCHER_BOOTSTRAP_PASSWORD}"
    echo ""
    echo "  IMPORTANT: Change the admin password immediately!"
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
}

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
    install_cert_manager
    install_rancher
    post_install
    
    log "Rancher setup complete!"
}

# Run if executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi