#!/usr/bin/env bash
#===============================================================================
# GitLab CE Native Installation + Repo Bootstrap for Raspberry Pi (arm64)
#
# Installs GitLab CE via official arm64 deb package on the central Pi node,
# then bootstraps the kube-world repo inside it so Flux (and anything else
# in the cluster) can pull from it immediately after bootstrap completes.
#
# GitLab runs as a systemd service alongside K3s (not as a K8s workload)
# because the official gitlab/gitlab-ce Docker image is amd64-only.
#
# When the central node is upgraded to amd64 server hardware, GitLab can be
# migrated to run as a K8s workload using the manifests in apps/gitlab/.
#
# Phases:
#   1. check_prereqs     — SSH, arch, memory, disk
#   2. install_gitlab    — apt install gitlab-ce (5-10 min)
#   3. configure_gitlab  — pi-tuning.rb (Puma/Postgres/nginx port 8180)
#   4. wait_ready        — poll /-/readiness until 200
#   5. rotate_root_pass  — set root password to known value
#   6. create_root_pat   — create personal access token via API
#   7. create_project    — create root/kube-world project
#   8. push_repo         — git push local contents to GitLab
#   9. create_deploy_token — create read-only token for Flux
#  10. write_credentials — write deploy token to stdout / file for parent script
#
# Prerequisites:
#   - SSH access to the Pi (admin user with sudo)
#   - Pi running Debian/Ubuntu arm64
#   - At least 4GB free RAM
#   - Local git repo clean (so we can push it)
#
# Usage:
#   ./scripts/install-gitlab.sh [options]
#
#   Options:
#     --pi-ip <ip>          Pi IP address (default: from inventory.ini)
#     --domain <domain>     Base domain (sets external_url to http://gitlab.<domain>)
#     --root-password <pw>  Root password to set (default: random or RANCHER_BOOTSTRAP_PASSWORD)
#     --ssh-user <user>     SSH user (default: admin)
#     --state-file <path>   Write credentials JSON to this file (default: /tmp/gitlab-bootstrap.state)
#     --skip-repo-push      Only install GitLab; don't push repo or create tokens
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
DOMAIN="${DOMAIN:-}"
ROOT_PASSWORD="${GITLAB_ROOT_PASSWORD:-${RANCHER_BOOTSTRAP_PASSWORD:-}}"
STATE_FILE="/tmp/gitlab-bootstrap.state"
SKIP_REPO_PUSH=false
DRY_RUN=false
OIDC_CLIENT_ID="${GITLAB_OIDC_CLIENT_ID:-}"
OIDC_CLIENT_SECRET="${GITLAB_OIDC_CLIENT_SECRET:-}"
OIDC_ISSUER="${GITLAB_OIDC_ISSUER:-}"

log()   { echo -e "${GREEN}[GITLAB]${NC} $*"; }
warn()  { echo -e "${YELLOW}[GITLAB]${NC} $*"; }
error() { echo -e "${RED}[GITLAB]${NC} $*" >&2; }
debug() { echo -e "${BLUE}[GITLAB]${NC} $*"; }

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
            --domain)
                DOMAIN="$2"
                shift 2
                ;;
            --root-password)
                ROOT_PASSWORD="$2"
                shift 2
                ;;
            --ssh-user)
                SSH_USER="$2"
                shift 2
                ;;
            --state-file)
                STATE_FILE="$2"
                shift 2
                ;;
            --skip-repo-push)
                SKIP_REPO_PUSH=true
                shift
                ;;
            --oidc-client-id)
                OIDC_CLIENT_ID="$2"
                shift 2
                ;;
            --oidc-client-secret)
                OIDC_CLIENT_SECRET="$2"
                shift 2
                ;;
            --oidc-issuer)
                OIDC_ISSUER="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            -h|--help)
                sed -n '2,/^#====/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
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
            PI_IP=$(awk '/^\[masters\]/{found=1; next} found && /^[^#\[]/ && NF{print; exit}' "$inventory" \
                | sed 's/.*ansible_host=//' | awk '{print $1}')
        fi
    fi

    if [[ -z "$PI_IP" || "$PI_IP" == "CHANGE_ME" ]]; then
        error "Pi IP not configured. Use --pi-ip or update inventory.ini"
        exit 1
    fi

    log "Target Pi: ${PI_IP}"
    if [[ -n "$DOMAIN" ]]; then
        log "GitLab external URL: http://gitlab.${DOMAIN}"
    else
        log "GitLab external URL: http://gitlab.${PI_IP}.nip.io (no DOMAIN set)"
    fi
}

#===============================================================================
# SSH helpers
#===============================================================================
run_on_pi() {
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "${SSH_USER}@${PI_IP}" "$@"
}

# Run a command on the Pi, capturing exit code without set -e aborting us
run_on_pi_safe() {
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        "${SSH_USER}@${PI_IP}" "$@" 2>&1 || true
}

#===============================================================================
# Phase 1: Prerequisites
#===============================================================================
check_prereqs() {
    log "Checking prerequisites..."

    if ! run_on_pi "echo ok" &>/dev/null; then
        error "Cannot SSH to ${SSH_USER}@${PI_IP}"
        exit 1
    fi

    local arch
    arch=$(run_on_pi "uname -m")
    if [[ "$arch" != "aarch64" ]]; then
        warn "Expected aarch64, got ${arch}. Proceeding anyway..."
    fi

    local avail_mb
    avail_mb=$(run_on_pi "awk '/MemAvailable/ {print int(\$2/1024)}' /proc/meminfo")
    log "Available memory: ${avail_mb}MB"
    if [[ "$avail_mb" -lt 3000 ]]; then
        warn "Less than 3GB available. GitLab may struggle. Recommend 4GB+ free."
    fi

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
# Phase 2: Install GitLab CE
#===============================================================================
install_gitlab() {
    if run_on_pi "command -v gitlab-ctl" &>/dev/null; then
        log "GitLab already installed on ${PI_IP}"
        return 0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would install GitLab CE via official arm64 deb package"
        return 0
    fi

    local external_url
    if [[ -n "$DOMAIN" ]]; then
        external_url="http://gitlab.${DOMAIN}"
    else
        external_url="http://gitlab.${PI_IP}.nip.io"
    fi

    log "Installing GitLab CE on ${PI_IP}..."

    # Wait for any existing apt/dpkg locks and fix interrupted dpkg state
    log "Waiting for apt lock..."
    run_on_pi "while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 5; done" 2>&1
    # Fix any half-configured/broken packages from a previous failed install.
    # If gitlab-ce is in iF/iU state but binaries were removed, dpkg --configure
    # fails because the post-inst script references missing files. Force-purge first.
    local pkg_state
    pkg_state=$(run_on_pi "dpkg -l gitlab-ce 2>/dev/null | tail -1 | awk '{print \$1}'" || echo "")
    if [[ "$pkg_state" == "iF" || "$pkg_state" == "iU" || "$pkg_state" == "rc" ]]; then
        log "Purging broken gitlab-ce package state (${pkg_state})..."
        run_on_pi "sudo dpkg --purge --force-remove-reinstreq gitlab-ce 2>/dev/null" 2>&1 | tail -3 || true
    fi
    run_on_pi "sudo dpkg --configure -a 2>/dev/null" 2>&1 | tail -3 || true

    log "Installing dependencies..."
    run_on_pi "sudo apt-get update -qq && sudo apt-get install -y -qq curl openssh-server ca-certificates tzdata perl postfix" 2>&1 | tail -5

    log "Adding GitLab CE repository..."
    run_on_pi "curl -sS https://packages.gitlab.com/install/repositories/gitlab/gitlab-ce/script.deb.sh | sudo bash" 2>&1 | tail -5

    # Pre-create the gitlab.rb config directory and write the pi-tuning
    # config BEFORE the apt install. The gitlab-ce deb post-install script
    # runs `gitlab-ctl reconfigure` which reads /etc/gitlab/gitlab.rb. If
    # our tuning isn't in place at that point, the initial reconfigure
    # tries to start node-exporter (Prometheus monitoring) which crashes
    # on resource-constrained Pis and fails the entire install.
    log "Pre-creating Pi-optimized config (applied during initial reconfigure)..."
    run_on_pi "sudo mkdir -p /etc/gitlab/gitlab.rb.d"
    # Write a minimal pre-install tuning file that disables services known
    # to crash during initial install. Full tuning is applied in configure_gitlab.
    run_on_pi "sudo tee /etc/gitlab/gitlab.rb.d/00-pre-install.rb > /dev/null" <<'PREINSTALL'
# Minimal pre-install config to prevent crashes during initial reconfigure.
# Full Pi tuning is applied by configure_gitlab (pi-tuning.rb) afterward.
prometheus_monitoring['enable'] = false
registry['enable'] = false
gitlab_pages['enable'] = false
mattermost['enable'] = false
PREINSTALL
    # Create gitlab.rb with the .d include if it doesn't exist yet
    run_on_pi "sudo test -f /etc/gitlab/gitlab.rb || echo 'Dir[\"/etc/gitlab/gitlab.rb.d/*.rb\"].each { |f| eval(File.read(f)) }' | sudo tee /etc/gitlab/gitlab.rb > /dev/null"
    # Also ensure the .d include line exists (idempotent)
    run_on_pi "sudo grep -q 'gitlab.rb.d' /etc/gitlab/gitlab.rb || echo 'Dir[\"/etc/gitlab/gitlab.rb.d/*.rb\"].each { |f| eval(File.read(f)) }' | sudo tee -a /etc/gitlab/gitlab.rb > /dev/null"

    log "Installing GitLab CE package (this takes 10-25 minutes on Pi)..."

    # Run apt install via nohup so it continues even if SSH disconnects.
    # The gitlab-ce post-inst script runs gitlab-ctl reconfigure which
    # takes 10-20 min on a Pi and has a known race condition with the
    # gitlab-runsvdir systemd service. Running via nohup + polling lets
    # us detect and fix the race without the SSH session hanging.
    run_on_pi "nohup sudo EXTERNAL_URL='${external_url}' apt-get install -y gitlab-ce > /tmp/gitlab-install.log 2>&1 &"
    log "  apt-get running in background on Pi, polling for completion..."

    # Phase 2a: Wait for apt to finish extracting the package. The nohup'd
    # apt-get unpacks files then runs the post-inst script (gitlab-ctl
    # reconfigure). The reconfigure usually fails due to the runsvdir race.
    # We wait for apt to exit (success or failure), then handle the rest.
    local max_wait=600  # 10 min for package extraction (reconfigure may fail)
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        sleep 15
        waited=$((waited + 15))
        local apt_running
        apt_running=$(run_on_pi "pgrep -c 'apt-get' 2>/dev/null" 2>&1 || echo "0")
        if [[ "$apt_running" == "0" ]]; then
            log "  apt-get finished ($((waited))s)"
            break
        fi
        if (( waited % 60 == 0 )); then
            debug "  [${waited}s] apt-get still running..."
        fi
    done

    # Phase 2b: Check dpkg state and handle the runsvdir race condition.
    local state
    state=$(run_on_pi "dpkg -l gitlab-ce 2>/dev/null | tail -1 | awk '{print \$1}'" 2>&1 || echo "")

    if [[ "$state" == "ii" ]]; then
        log "  GitLab CE package fully installed ✓"
    elif [[ "$state" == "iF" || "$state" == "iU" ]]; then
        # Half-configured = runsvdir race. Fix runsvdir ONCE and run
        # gitlab-ctl reconfigure directly (not dpkg --configure, which
        # restarts the full post-inst from scratch each time).
        log "  Package half-configured ($state) — fixing runsvdir..."

        # Fix runsvdir: reset failed state, start, and VERIFY it stays up
        local rsv_attempts=0
        while [[ $rsv_attempts -lt 5 ]]; do
            run_on_pi "sudo systemctl reset-failed gitlab-runsvdir 2>/dev/null; sudo systemctl start gitlab-runsvdir" 2>&1 || true
            sleep 5
            local rsv_active
            rsv_active=$(run_on_pi "sudo systemctl is-active gitlab-runsvdir 2>&1" || echo "failed")
            if [[ "$rsv_active" == "active" ]]; then
                log "  gitlab-runsvdir service running ✓"
                break
            fi
            rsv_attempts=$((rsv_attempts + 1))
            debug "  runsvdir not ready yet, retrying ($rsv_attempts/5)..."
            sleep 10
        done

        # Run gitlab-ctl reconfigure directly. This is idempotent and picks
        # up where the failed post-inst reconfigure left off. Much more
        # efficient than dpkg --configure which restarts the full post-inst.
        log "  Running gitlab-ctl reconfigure (10-20 min on Pi)..."
        run_on_pi "sudo gitlab-ctl reconfigure" 2>&1 | tail -5 || true

        # Now mark the package as fully configured in dpkg
        log "  Finalizing dpkg state..."
        run_on_pi "sudo dpkg --configure gitlab-ce" 2>&1 | tail -3 || true

        state=$(run_on_pi "dpkg -l gitlab-ce 2>/dev/null | tail -1 | awk '{print \$1}'" 2>&1 || echo "")
        if [[ "$state" == "ii" ]]; then
            log "  GitLab CE package fixed and fully installed ✓"
        else
            error "GitLab CE still in state '${state}' after reconfigure"
            error "Check: ssh admin@${PI_IP} 'sudo gitlab-ctl reconfigure'"
            return 1
        fi
    else
        error "GitLab CE install failed. dpkg state: ${state:-unknown}"
        error "Check /tmp/gitlab-install.log on the Pi for details"
        return 1
    fi

    log "GitLab CE package installed"
}

#===============================================================================
# Phase 3: Pi-optimized Configuration
#===============================================================================
configure_gitlab() {
    log "Applying Pi-optimized configuration..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would apply Pi resource tuning to /etc/gitlab/gitlab.rb.d/pi-tuning.rb"
        return 0
    fi

    local external_url
    if [[ -n "$DOMAIN" ]]; then
        external_url="http://gitlab.${DOMAIN}"
    else
        external_url="http://gitlab.${PI_IP}.nip.io"
    fi

    # Write pi-tuning.rb. Includes:
    # - Resource tuning for 16GB Pi shared with K3s
    # - nginx bound to port 8180 (so Traefik on node port 80 doesn't conflict)
    # - external_url matches what Traefik will serve so GitLab generates correct URLs
    run_on_pi "sudo mkdir -p /etc/gitlab/gitlab.rb.d"
    run_on_pi "sudo tee /etc/gitlab/gitlab.rb.d/pi-tuning.rb > /dev/null" <<PICONFIG
# Pi 5 (16GB) resource tuning for GitLab CE
# Applied by kube-world/scripts/install-gitlab.sh

# External URL — what users see. Traffic is routed via Traefik HTTPRoute.
external_url '${external_url}'

# Bind nginx to port 8180 so it doesn't conflict with anything on node port 80.
# Traefik (in K3s) reverse-proxies traffic via the 'gitlab' Service in the
# 'gitlab' namespace, whose manual Endpoints point at this host's IP:8180.
nginx['listen_port'] = 8180
nginx['listen_https'] = false

# Tell GitLab the real host/port it's reachable at (for redirects, webhooks, etc)
nginx['real_ip_header'] = 'X-Forwarded-For'
nginx['real_ip_recursive'] = 'on'
nginx['real_ip_trusted_addresses'] = ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '100.64.0.0/10']

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

    # Add OIDC configuration if Zitadel credentials are available.
    # This enables "Sign in with Zitadel" on GitLab's login page from
    # first boot — no manual reconfigure needed after identity setup.
    if [[ -n "$OIDC_CLIENT_ID" && -n "$OIDC_CLIENT_SECRET" && -n "$OIDC_ISSUER" ]]; then
        log "Adding OIDC configuration (Zitadel)..."
        local gitlab_redirect="http://gitlab.${DOMAIN:-kubew.dev}/users/auth/openid_connect/callback"
        run_on_pi "sudo tee /etc/gitlab/gitlab.rb.d/oidc.rb > /dev/null" <<OIDCCONFIG
# Zitadel OIDC configuration — auto-generated by install-gitlab.sh
# Enables SSO login via auth.${DOMAIN:-kubew.dev}

gitlab_rails['omniauth_enabled'] = true
gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']
gitlab_rails['omniauth_sync_email_from_provider'] = 'openid_connect'
gitlab_rails['omniauth_sync_profile_from_provider'] = ['openid_connect']
gitlab_rails['omniauth_block_auto_created_users'] = false
gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']

gitlab_rails['omniauth_providers'] = [
  {
    name: "openid_connect",
    label: "Zitadel",
    icon: nil,
    args: {
      name: "openid_connect",
      scope: ["openid", "profile", "email"],
      response_type: "code",
      issuer: "${OIDC_ISSUER}",
      discovery: true,
      client_auth_method: "basic",
      uid_field: "sub",
      pkce: true,
      client_options: {
        identifier: "${OIDC_CLIENT_ID}",
        secret: "${OIDC_CLIENT_SECRET}",
        redirect_uri: "${gitlab_redirect}"
      }
    }
  }
]
OIDCCONFIG
    else
        debug "No OIDC credentials provided — GitLab will use local auth only"
    fi

    # Ensure the .d directory is evaluated by the main config
    run_on_pi "sudo grep -q 'gitlab.rb.d' /etc/gitlab/gitlab.rb || echo 'Dir[\"/etc/gitlab/gitlab.rb.d/*.rb\"].each { |f| eval(File.read(f)) }' | sudo tee -a /etc/gitlab/gitlab.rb > /dev/null"

    log "Reconfiguring GitLab with Pi-optimized settings (3-5 min)..."
    run_on_pi "sudo gitlab-ctl reconfigure" 2>&1 | tail -10

    log "Configuration applied"
}

#===============================================================================
# Phase 4: Wait for GitLab to become ready
#===============================================================================
wait_for_gitlab_ready() {
    log "Waiting for GitLab to be ready..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would poll GitLab /-/readiness"
        return 0
    fi

    local max_attempts=60  # 5 minutes
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        local http_code
        http_code=$(run_on_pi "curl -s -o /dev/null -w '%{http_code}' http://localhost:8180/-/readiness?all=1 --max-time 5" 2>&1 || echo "000")
        if [[ "$http_code" == "200" ]]; then
            log "GitLab is ready ✓"
            return 0
        fi
        debug "  [$((attempt * 5))s] GitLab not ready yet (HTTP ${http_code})"
        sleep 5
        attempt=$((attempt + 1))
    done

    error "GitLab did not become ready within 5 minutes"
    return 1
}

#===============================================================================
# Phase 5: Rotate root password to known value
#===============================================================================
rotate_root_password() {
    if [[ -z "$ROOT_PASSWORD" ]]; then
        # Generate random password if none provided
        ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
        log "Generated random root password (will be saved to state file)"
    fi

    log "Setting GitLab root password..."
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would set root password via gitlab-rails runner"
        return 0
    fi

    # Use gitlab-rails runner to set the password non-interactively.
    # gitlab-rails drops privileges to the 'git' user, so any temp file
    # must be readable by that user. We write the password to a file
    # owned by git:git with mode 600, run the rails script, then delete.
    local remote_tmp="/tmp/gitlab-pw-$$"
    # shellcheck disable=SC2029
    ssh "${SSH_USER}@${PI_IP}" "cat > ${remote_tmp} && sudo chown git:git ${remote_tmp} && sudo chmod 600 ${remote_tmp}" <<< "$ROOT_PASSWORD"

    local rails_script
    rails_script='pw = File.read(ENV["PW_FILE"]).chomp; u = User.find_by_username("root"); u.password = pw; u.password_confirmation = pw; u.password_automatically_set = false; u.save!; puts "ok"'

    local result
    result=$(run_on_pi "sudo PW_FILE=${remote_tmp} gitlab-rails runner '${rails_script}'" 2>&1 || true)
    run_on_pi "sudo rm -f ${remote_tmp}" || true

    if echo "$result" | grep -q "^ok$"; then
        log "Root password set ✓"
    else
        error "Failed to set root password:"
        echo "$result"
        return 1
    fi

    # Remove the initial_root_password file now that we have a known password
    run_on_pi "sudo rm -f /etc/gitlab/initial_root_password" 2>/dev/null || true
}

#===============================================================================
# Phase 6: Create a Personal Access Token for root via API
#===============================================================================
create_root_pat() {
    log "Creating root personal access token..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would POST /oauth/token then create PAT"
        ROOT_PAT="dry-run-token"
        return 0
    fi

    local gitlab_url="http://${PI_IP}:8180"

    # Get OAuth token using Resource Owner Password Credentials grant
    local oauth_resp
    oauth_resp=$(run_on_pi "curl -s -X POST \
        -H 'Content-Type: application/json' \
        -d '{\"grant_type\":\"password\",\"username\":\"root\",\"password\":\"${ROOT_PASSWORD}\"}' \
        ${gitlab_url}/oauth/token")

    local oauth_token
    oauth_token=$(echo "$oauth_resp" | jq -r '.access_token // empty' 2>/dev/null || echo "")
    if [[ -z "$oauth_token" ]]; then
        error "Failed to obtain OAuth token:"
        echo "$oauth_resp"
        return 1
    fi
    debug "OAuth token obtained"

    # Create a personal access token via the v4 API
    local pat_resp
    pat_resp=$(run_on_pi "curl -s -X POST \
        -H 'Authorization: Bearer ${oauth_token}' \
        -H 'Content-Type: application/json' \
        -d '{\"name\":\"kube-world-bootstrap\",\"scopes\":[\"api\",\"write_repository\"],\"expires_at\":\"$(date -v+1y +%Y-%m-%d 2>/dev/null || date -d '+1 year' +%Y-%m-%d)\"}' \
        ${gitlab_url}/api/v4/users/1/personal_access_tokens")

    ROOT_PAT=$(echo "$pat_resp" | jq -r '.token // empty' 2>/dev/null || echo "")
    if [[ -z "$ROOT_PAT" ]]; then
        error "Failed to create PAT:"
        echo "$pat_resp"
        return 1
    fi

    log "Personal access token created ✓"
}

#===============================================================================
# Phase 7: Create the root/kube-world project
#===============================================================================
create_project() {
    log "Creating root/kube-world project..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would POST /api/v4/projects"
        return 0
    fi

    local gitlab_url="http://${PI_IP}:8180"

    # Check if project exists
    local existing
    existing=$(run_on_pi "curl -s -H 'PRIVATE-TOKEN: ${ROOT_PAT}' \
        '${gitlab_url}/api/v4/projects/root%2Fkube-world'" 2>&1)

    if echo "$existing" | jq -e '.id' >/dev/null 2>&1; then
        log "Project root/kube-world already exists"
        return 0
    fi

    # Create project
    local create_resp
    create_resp=$(run_on_pi "curl -s -X POST \
        -H 'PRIVATE-TOKEN: ${ROOT_PAT}' \
        -H 'Content-Type: application/json' \
        -d '{\"name\":\"kube-world\",\"path\":\"kube-world\",\"visibility\":\"private\",\"initialize_with_readme\":false,\"default_branch\":\"main\"}' \
        ${gitlab_url}/api/v4/projects")

    if echo "$create_resp" | jq -e '.id' >/dev/null 2>&1; then
        log "Project created ✓"
    else
        error "Failed to create project:"
        echo "$create_resp"
        return 1
    fi
}

#===============================================================================
# Phase 8: Push the local repo to GitLab
#===============================================================================
push_repo() {
    log "Pushing local repo to GitLab..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would push repo to GitLab"
        return 0
    fi

    # Use the Pi IP directly since DNS may not be ready yet.
    # Git HTTP Basic auth with root:PAT works for pushes.
    local push_url="http://root:${ROOT_PAT}@${PI_IP}:8180/root/kube-world.git"

    # Use a temp remote so we don't mess with the user's git remotes
    cd "$REPO_ROOT"
    git remote remove gitlab-bootstrap 2>/dev/null || true
    git remote add gitlab-bootstrap "$push_url"

    # Push current branch as main. Force since the empty GitLab project may
    # have a server-side initial commit (shouldn't with initialize_with_readme
    # false, but be safe).
    if ! git push gitlab-bootstrap HEAD:refs/heads/main --force 2>&1 | grep -v "^remote:" | grep -v "^To http"; then
        warn "git push may have reported messages above — verifying..."
    fi

    git remote remove gitlab-bootstrap 2>/dev/null || true

    # Verify by querying project's default branch
    local gitlab_url="http://${PI_IP}:8180"
    local branch_check
    branch_check=$(run_on_pi "curl -s -H 'PRIVATE-TOKEN: ${ROOT_PAT}' \
        '${gitlab_url}/api/v4/projects/root%2Fkube-world/repository/branches/main'" 2>&1)
    if echo "$branch_check" | jq -e '.name == "main"' >/dev/null 2>&1; then
        local commit
        commit=$(echo "$branch_check" | jq -r '.commit.short_id')
        log "Repo pushed ✓ (main @ ${commit})"
    else
        error "Push verification failed:"
        echo "$branch_check"
        return 1
    fi
}

#===============================================================================
# Phase 9: Create a project deploy token for Flux
#===============================================================================
create_deploy_token() {
    log "Creating project deploy token for Flux..."

    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would POST /api/v4/projects/.../deploy_tokens"
        DEPLOY_TOKEN_USER="flux-bootstrap"
        DEPLOY_TOKEN="dry-run-deploy-token"
        return 0
    fi

    local gitlab_url="http://${PI_IP}:8180"

    # Deploy tokens are read-only credentials scoped to a project.
    # Flux only needs read_repository to clone.
    local resp
    resp=$(run_on_pi "curl -s -X POST \
        -H 'PRIVATE-TOKEN: ${ROOT_PAT}' \
        -H 'Content-Type: application/json' \
        -d '{\"name\":\"flux-read\",\"scopes\":[\"read_repository\"],\"username\":\"flux-bootstrap\"}' \
        ${gitlab_url}/api/v4/projects/root%2Fkube-world/deploy_tokens")

    DEPLOY_TOKEN=$(echo "$resp" | jq -r '.token // empty' 2>/dev/null || echo "")
    DEPLOY_TOKEN_USER=$(echo "$resp" | jq -r '.username // "flux-bootstrap"' 2>/dev/null || echo "flux-bootstrap")

    if [[ -z "$DEPLOY_TOKEN" ]]; then
        # Might already exist with that name — deploy tokens can't be retrieved,
        # only re-created with a different name
        warn "Deploy token creation failed — attempting with unique name..."
        local unique_name="flux-read-$(date +%s)"
        resp=$(run_on_pi "curl -s -X POST \
            -H 'PRIVATE-TOKEN: ${ROOT_PAT}' \
            -H 'Content-Type: application/json' \
            -d '{\"name\":\"${unique_name}\",\"scopes\":[\"read_repository\"],\"username\":\"flux-bootstrap\"}' \
            ${gitlab_url}/api/v4/projects/root%2Fkube-world/deploy_tokens")
        DEPLOY_TOKEN=$(echo "$resp" | jq -r '.token // empty' 2>/dev/null || echo "")
        DEPLOY_TOKEN_USER=$(echo "$resp" | jq -r '.username // "flux-bootstrap"' 2>/dev/null || echo "flux-bootstrap")
    fi

    if [[ -z "$DEPLOY_TOKEN" ]]; then
        error "Failed to create deploy token:"
        echo "$resp"
        return 1
    fi

    log "Deploy token created ✓"
}

#===============================================================================
# Phase 10: Write credentials to state file
#===============================================================================
write_state_file() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY RUN] Would write state to ${STATE_FILE}"
        return 0
    fi

    umask 077
    cat > "$STATE_FILE" <<EOF
{
  "pi_ip": "${PI_IP}",
  "domain": "${DOMAIN}",
  "external_url": "http://gitlab.${DOMAIN:-${PI_IP}.nip.io}",
  "root_password": "${ROOT_PASSWORD}",
  "root_pat": "${ROOT_PAT:-}",
  "deploy_token_user": "${DEPLOY_TOKEN_USER:-}",
  "deploy_token": "${DEPLOY_TOKEN:-}",
  "bootstrapped_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 600 "$STATE_FILE"
    log "State written to ${STATE_FILE} (mode 600)"
}

#===============================================================================
# Summary
#===============================================================================
print_summary() {
    local external_url="http://gitlab.${DOMAIN:-${PI_IP}.nip.io}"
    echo ""
    echo "=============================================="
    echo "  GitLab CE Bootstrap Complete"
    echo "=============================================="
    echo ""
    echo "  URL:              ${external_url}"
    echo "  Username:         root"
    echo "  Password:         ${ROOT_PASSWORD}"
    echo ""
    echo "  Project:          ${external_url}/root/kube-world"
    echo "  Deploy token:     ${DEPLOY_TOKEN_USER:-<none>}"
    echo ""
    echo "  State file:       ${STATE_FILE}"
    echo "  (parent bootstrap.sh reads deploy token from here to create"
    echo "   the gitlab-credentials K8s secret for Flux)"
    echo ""
    echo "=============================================="
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
    wait_for_gitlab_ready

    if [[ "$SKIP_REPO_PUSH" == "true" ]]; then
        log "Skipping repo bootstrap (--skip-repo-push)"
        return 0
    fi

    rotate_root_password
    create_root_pat
    create_project
    push_repo
    create_deploy_token
    write_state_file
    print_summary

    log "Done!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
