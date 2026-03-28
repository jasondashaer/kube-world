#!/usr/bin/env bash
#===============================================================================
# GitLab CE Native Installation Script for Raspberry Pi (arm64)
#
# Installs GitLab CE via official arm64 deb package on the central Pi node.
# GitLab runs as a systemd service alongside K3s (not as a K8s workload)
# because the official gitlab/gitlab-ce Docker image is amd64-only.
#
# When the central node is upgraded to amd64 server hardware, GitLab can be
# migrated to run as a K8s workload using the manifests in apps/gitlab/.
#
# Prerequisites:
#   - SSH access to the Pi (admin user with sudo)
#   - Pi running Debian/Ubuntu arm64
#   - At least 4GB free RAM
#
# Usage:
#   ./scripts/install-gitlab.sh [options]
#   Options:
#     --pi-ip <ip>          Pi IP address (default: from inventory.ini)
#     --external-url <url>  GitLab external URL (default: http://gitlab.<pi-ip>.nip.io)
#     --ssh-user <user>     SSH user (default: admin)
#     --dry-run             Show what would be done
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
PI_IP=""
SSH_USER="admin"
EXTERNAL_URL=""
DRY_RUN=false

log() { echo -e "${GREEN}[GITLAB]${NC} $*"; }
warn() { echo -e "${YELLOW}[GITLAB]${NC} $*"; }
error() { echo -e "${RED}[GITLAB]${NC} $*" >&2; }

#===============================================================================
# Parse Arguments
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --pi-ip)
                PI_IP="$2"
                shift 2
                ;;
            --external-url)
                EXTERNAL_URL="$2"
                shift 2
                ;;
            --ssh-user)
                SSH_USER="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --pi-ip <ip>          Pi IP address (default: from inventory.ini)"
                echo "  --external-url <url>  GitLab external URL"
                echo "  --ssh-user <user>     SSH user (default: admin)"
                echo "  --dry-run             Show what would be done"
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
# Resolve Pi IP from inventory if not provided
#===============================================================================
resolve_pi_ip() {
    if [[ -z "$PI_IP" ]]; then
        local inventory="${REPO_ROOT}/pi-setup/inventory.ini"
        if [[ -f "$inventory" ]]; then
            PI_IP=$(awk '/^\[masters\]/{found=1; next} found && /^[^#\[]/ && NF{print; exit}' "$inventory" | sed 's/.*ansible_host=//' | awk '{print $1}')
        fi
    fi

    if [[ -z "$PI_IP" || "$PI_IP" == "CHANGE_ME" ]]; then
        error "Pi IP not configured. Use --pi-ip or update inventory.ini"
        exit 1
    fi

    if [[ -z "$EXTERNAL_URL" ]]; then
        EXTERNAL_URL="http://gitlab.${PI_IP}.nip.io"
    fi

    log "Target Pi: ${PI_IP}"
    log "GitLab URL: ${EXTERNAL_URL}"
}

#===============================================================================
# SSH helper
#===============================================================================
run_on_pi() {
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=no "${SSH_USER}@${PI_IP}" "$@"
}

#===============================================================================
# Check prerequisites
#===============================================================================
check_prereqs() {
    log "Checking prerequisites..."

    # Test SSH
    if ! run_on_pi "echo ok" &>/dev/null; then
        error "Cannot SSH to ${SSH_USER}@${PI_IP}"
        exit 1
    fi

    # Check architecture
    local arch
    arch=$(run_on_pi "uname -m")
    if [[ "$arch" != "aarch64" ]]; then
        warn "Expected aarch64, got ${arch}. Proceeding anyway..."
    fi

    # Check available memory
    local avail_mb
    avail_mb=$(run_on_pi "awk '/MemAvailable/ {print int(\$2/1024)}' /proc/meminfo")
    log "Available memory: ${avail_mb}MB"
    if [[ "$avail_mb" -lt 3000 ]]; then
        warn "Less than 3GB available. GitLab may struggle. Recommend 4GB+ free."
    fi

    # Check disk space
    local avail_gb
    avail_gb=$(run_on_pi "df -BG / | tail -1 | awk '{print int(\$4)}'")
    log "Available disk: ${avail_gb}GB"
    if [[ "$avail_gb" -lt 5 ]]; then
        error "Less than 5GB disk space. GitLab needs at least 5GB free."
        exit 1
    fi

    log "Prerequisites OK"
}

#===============================================================================
# Install GitLab CE
#===============================================================================
install_gitlab() {
    log "Installing GitLab CE on ${PI_IP}..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would install GitLab CE via official arm64 deb package"
        log "[DRY RUN] External URL: ${EXTERNAL_URL}"
        return 0
    fi

    # Check if already installed
    if run_on_pi "command -v gitlab-ctl" &>/dev/null; then
        log "GitLab is already installed. Checking status..."
        run_on_pi "sudo gitlab-ctl status" 2>&1 || true
        log "To reconfigure: sudo gitlab-ctl reconfigure"
        return 0
    fi

    # Install dependencies
    log "Installing dependencies..."
    run_on_pi "sudo apt-get update -qq && sudo apt-get install -y -qq curl openssh-server ca-certificates tzdata perl postfix" 2>&1 | tail -5

    # Add GitLab package repository
    log "Adding GitLab CE repository..."
    run_on_pi "curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash" 2>&1 | tail -5

    # Install GitLab CE with external URL
    log "Installing GitLab CE package (this takes 5-10 minutes on Pi)..."
    run_on_pi "sudo EXTERNAL_URL='${EXTERNAL_URL}' apt-get install -y gitlab-ce" 2>&1 | tail -20

    log "GitLab CE package installed"
}

#===============================================================================
# Configure GitLab for Pi resource constraints
#===============================================================================
configure_gitlab() {
    log "Applying Pi-optimized configuration..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would apply Pi resource tuning to /etc/gitlab/gitlab.rb"
        return 0
    fi

    # Apply resource-tuned configuration
    run_on_pi "sudo mkdir -p /etc/gitlab/gitlab.rb.d"
    run_on_pi "sudo tee /etc/gitlab/gitlab.rb.d/pi-tuning.rb > /dev/null" <<'PICONFIG'
# Pi 5 (16GB) resource tuning for GitLab CE
# Applied by kube-world/scripts/install-gitlab.sh

# Puma (web server) - reduce workers for arm64
puma['worker_processes'] = 2
puma['min_threads'] = 1
puma['max_threads'] = 4
puma['per_worker_max_memory_mb'] = 650

# Sidekiq - single process, fewer threads
sidekiq['max_concurrency'] = 5
sidekiq['min_concurrency'] = 1

# PostgreSQL - tuned for 16GB shared with K3s
postgresql['shared_buffers'] = '128MB'
postgresql['work_mem'] = '8MB'
postgresql['maintenance_work_mem'] = '64MB'
postgresql['effective_cache_size'] = '256MB'
postgresql['max_worker_processes'] = 4

# Redis - limit memory
redis['maxmemory'] = '256mb'
redis['maxmemory_policy'] = 'allkeys-lru'

# Disable monitoring stack (Rancher/Prometheus handles this)
prometheus_monitoring['enable'] = false

# Disable unused services
registry['enable'] = false
gitlab_pages['enable'] = false
mattermost['enable'] = false
gitlab_rails['terraform_state_enabled'] = false

# Git LFS enabled
gitlab_rails['lfs_enabled'] = true

# Logging - keep it lean
logging['logrotate_frequency'] = 'weekly'
logging['logrotate_size'] = '10M'
logging['logrotate_rotate'] = 5
PICONFIG

    # Ensure the .d directory is used by the main config
    run_on_pi "sudo grep -q 'gitlab.rb.d' /etc/gitlab/gitlab.rb || echo 'Dir[\"/etc/gitlab/gitlab.rb.d/*.rb\"].each { |f| eval(File.read(f)) }' | sudo tee -a /etc/gitlab/gitlab.rb > /dev/null"

    log "Reconfiguring GitLab with Pi-optimized settings..."
    run_on_pi "sudo gitlab-ctl reconfigure" 2>&1 | tail -10

    log "Configuration applied"
}

#===============================================================================
# Verify installation
#===============================================================================
verify_gitlab() {
    log "Verifying GitLab installation..."

    # Check service status
    local status
    status=$(run_on_pi "sudo gitlab-ctl status" 2>&1)
    echo "$status"

    # Check if web interface responds
    local http_code
    http_code=$(run_on_pi "curl -s -o /dev/null -w '%{http_code}' http://localhost/-/readiness --max-time 10" 2>&1 || echo "000")

    if [[ "$http_code" == "200" ]]; then
        log "GitLab web interface is responding (HTTP 200)"
    else
        warn "GitLab web interface returned HTTP ${http_code} — it may still be starting up"
        warn "Check manually: curl -s http://localhost/-/readiness"
    fi

    # Get initial root password
    if run_on_pi "sudo test -f /etc/gitlab/initial_root_password" 2>/dev/null; then
        local password
        password=$(run_on_pi "sudo grep 'Password:' /etc/gitlab/initial_root_password | awk '{print \$2}'")
        echo ""
        echo "=============================================="
        echo "  GitLab CE Installed Successfully"
        echo "=============================================="
        echo ""
        echo "  URL:      ${EXTERNAL_URL}"
        echo "  Username: root"
        echo "  Password: ${password}"
        echo ""
        echo "  NOTE: The initial password file is auto-deleted"
        echo "  after 24 hours. Change it on first login."
        echo ""
        echo "  To manage GitLab:"
        echo "    ssh ${SSH_USER}@${PI_IP}"
        echo "    sudo gitlab-ctl status"
        echo "    sudo gitlab-ctl reconfigure"
        echo "    sudo gitlab-ctl restart"
        echo ""
        echo "=============================================="
    else
        echo ""
        echo "=============================================="
        echo "  GitLab CE Installed"
        echo "=============================================="
        echo ""
        echo "  URL: ${EXTERNAL_URL}"
        echo "  Initial password file not found."
        echo "  Reset with: sudo gitlab-rake 'gitlab:password:reset[root]'"
        echo ""
        echo "=============================================="
    fi
}

#===============================================================================
# Main
#===============================================================================
main() {
    echo ""
    echo "=============================================="
    echo "  GitLab CE Installation (Native arm64)"
    echo "  $(date '+%Y-%m-%d %H:%M:%S')"
    echo "=============================================="
    echo ""

    parse_args "$@"
    resolve_pi_ip
    check_prereqs
    install_gitlab
    configure_gitlab
    verify_gitlab

    log "Done!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
