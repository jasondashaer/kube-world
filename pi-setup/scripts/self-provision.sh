#!/usr/bin/env bash
#===============================================================================
# Self-provisioning script for kube-world edge nodes.
#
# Run on a fresh Pi after cloud-init completes. Installs Tailscale + K3s,
# joins the tailnet, and makes the node discoverable by the central cluster.
# Flux on central then deploys the full infrastructure stack automatically.
#
# Prerequisites (set via cloud-init write_files or environment):
#   TAILSCALE_AUTH_KEY  — reusable auth key from Terraform or API
#   NODE_ROLE           — "edge" (default) or "central"
#   NODE_NAME           — hostname for Tailscale (e.g., pi-edge-2)
#   K3S_VERSION         — K3s version to install (default: v1.34.6+k3s1)
#
# After this script completes:
#   1. Pi is on the Tailscale mesh (reachable from central)
#   2. K3s is running with traefik/servicelb disabled
#   3. Central cluster can register it with Karmada
#   4. Flux applies infrastructure/clusters/<edge>/ manifests
#
# Usage:
#   TAILSCALE_AUTH_KEY=tskey-... NODE_NAME=pi-edge-2 ./self-provision.sh
#===============================================================================
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[PROVISION]${NC} $*"; }
error() { echo -e "${RED}[PROVISION]${NC} $*" >&2; }

NODE_ROLE="${NODE_ROLE:-edge}"
NODE_NAME="${NODE_NAME:-$(hostname)}"
K3S_VERSION="${K3S_VERSION:-v1.34.6+k3s1}"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

LOG_FILE="/var/log/kube-world-provision.log"
exec > >(tee -a "$LOG_FILE") 2>&1

log "Starting self-provisioning..."
log "  Node: ${NODE_NAME} (role: ${NODE_ROLE})"
log "  K3s: ${K3S_VERSION}"

#===============================================================================
# 1. Wait for network
#===============================================================================
log "Waiting for network..."
until ping -c1 1.1.1.1 &>/dev/null; do
    sleep 5
done
log "Network ready ✓"

#===============================================================================
# 2. Install Tailscale
#===============================================================================
if ! command -v tailscale &>/dev/null; then
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
fi

if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
    error "TAILSCALE_AUTH_KEY not set — cannot join tailnet"
    error "Set it in /etc/kube-world/env or pass as environment variable"
    exit 1
fi

log "Joining Tailscale mesh..."
sudo tailscale up --authkey="$TAILSCALE_AUTH_KEY" --hostname="$NODE_NAME" --accept-routes

# Wait for Tailscale to be connected
local_ts_ip=""
for i in $(seq 1 30); do
    local_ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    [[ -n "$local_ts_ip" ]] && break
    sleep 2
done

if [[ -z "$local_ts_ip" ]]; then
    error "Tailscale did not connect after 60s"
    exit 1
fi
log "Tailscale connected ✓ (IP: ${local_ts_ip})"

#===============================================================================
# 3. Install K3s
#===============================================================================
if command -v k3s &>/dev/null; then
    log "K3s already installed"
else
    log "Installing K3s ${K3S_VERSION}..."
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="${K3S_VERSION}" \
        INSTALL_K3S_EXEC="server \
            --disable=traefik \
            --disable=servicelb \
            --tls-san=${local_ts_ip} \
            --tls-san=${NODE_NAME} \
            --node-name=${NODE_NAME} \
            --write-kubeconfig-mode=644" \
        sh -
fi

# Wait for K3s to be ready
log "Waiting for K3s..."
until sudo k3s kubectl get nodes &>/dev/null; do
    sleep 5
done
log "K3s ready ✓"

#===============================================================================
# 4. Label the node
#===============================================================================
if [[ "$NODE_ROLE" == "edge" ]]; then
    sudo k3s kubectl label node "$NODE_NAME" \
        workload-type=iot \
        topology.kubernetes.io/zone=edge \
        hardware=raspberry-pi \
        --overwrite 2>/dev/null || true
fi

#===============================================================================
# 5. Signal readiness
#===============================================================================
log ""
log "=============================================="
log "  Self-Provisioning Complete: ${NODE_NAME}"
log "=============================================="
log ""
log "  Tailscale IP: ${local_ts_ip}"
log "  K3s version:  ${K3S_VERSION}"
log "  Node role:    ${NODE_ROLE}"
log ""
log "  Next steps (from central cluster or CI):"
log "    1. Add ${NODE_NAME} to pi-setup/inventory.ini"
log "    2. Add infrastructure/clusters/<edge>/ manifests"
log "    3. Run: terraform apply (creates Cloudflare wildcard CNAME)"
log "    4. Register with Karmada:"
log "       karmadactl join ${NODE_NAME} --cluster-kubeconfig=<path>"
log "    5. Create Flux kubeconfig secret + Kustomization"
log "    6. Flux deploys full infrastructure stack automatically"
log "=============================================="
