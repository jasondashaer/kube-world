#!/usr/bin/env bash
#===============================================================================
# kube-world Setup Wizard
# Purpose: Interactive questionnaire that collects all inputs needed for
#          a fully automated bootstrap run. Generates .env.bootstrap and
#          optionally updates config.yaml.
#
# Usage:
#   ./scripts/setup.sh              # Interactive mode
#   ./scripts/setup.sh --validate   # Re-validate existing .env.bootstrap
#   ./scripts/setup.sh --reconfigure # Start over, ignoring existing values
#===============================================================================
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env.bootstrap"
CONFIG_FILE="${REPO_ROOT}/config.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# State — populated during questionnaire
PLATFORM=""
MODE=""
STACK=""
DOMAIN=""
CLOUDFLARE_API_TOKEN=""
TAILSCALE_API_TOKEN=""
TAILSCALE_AUTH_KEY=""
CENTRAL_TAILSCALE_IP=""
PI_IP=""
SSH_USER=""
SSH_KEY_PATH=""
RANCHER_BOOTSTRAP_PASSWORD=""
RANCHER_HOSTNAME=""
VALIDATE_ONLY=false
RECONFIGURE=false

#===============================================================================
# Helpers
#===============================================================================
print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║          kube-world Setup Wizard                ║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BLUE}${BOLD}── $1 ──${NC}"
    echo ""
}

info() { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $*"; }
err()  { echo -e "  ${RED}✗${NC} $*"; }
hint() { echo -e "  ${DIM}$*${NC}"; }

# Prompt with default value. Reads from existing env if available and not --reconfigure.
# Usage: prompt "Label" DEFAULT_VALUE VARIABLE_NAME [--secret]
# Type "-" to clear a stored value without losing the leave-blank-to-reuse feature.
prompt() {
    local label="$1"
    local default="$2"
    local varname="$3"
    local secret="${4:-}"
    local current="${!varname:-$default}"
    local display_default="$current"

    if [[ "$secret" == "--secret" && -n "$current" ]]; then
        # Show masked version of existing secret
        display_default="${current:0:6}...${current: -4}"
    fi

    if [[ -n "$display_default" ]]; then
        echo -ne "  ${BOLD}${label}${NC} [${DIM}${display_default}${NC}] ${DIM}(- to clear)${NC}: "
    else
        echo -ne "  ${BOLD}${label}${NC}: "
    fi

    local input
    if [[ "$secret" == "--secret" ]]; then
        read -rs input
        echo ""
    else
        read -r input
    fi

    # Clear keyword — explicitly set to empty
    if [[ "$input" == "-" ]]; then
        eval "$varname=\"\""
        return
    fi

    # Use input if provided, otherwise keep current/default
    if [[ -n "$input" ]]; then
        eval "$varname=\"$input\""
    elif [[ -n "$current" ]]; then
        eval "$varname=\"$current\""
    fi
}

# Yes/No prompt. Returns 0 for yes, 1 for no.
confirm() {
    local label="$1"
    local default="${2:-y}"
    local hint_text
    if [[ "$default" == "y" ]]; then
        hint_text="Y/n"
    else
        hint_text="y/N"
    fi

    echo -ne "  ${BOLD}${label}${NC} [${hint_text}]: "
    local input
    read -r input
    input="${input:-$default}"
    local lower
    lower=$(echo "$input" | tr '[:upper:]' '[:lower:]')
    [[ "$lower" == "y" || "$lower" == "yes" ]]
}

# Select from numbered options. Sets variable to selected value.
# Usage: select_option VARIABLE_NAME "Option 1" "Option 2" ...
select_option() {
    local varname="$1"
    shift
    local options=("$@")
    local current="${!varname:-}"
    local i=1

    for opt in "${options[@]}"; do
        local marker="  "
        if [[ "$opt" == "$current" ]]; then
            marker="${GREEN}→${NC}"
        fi
        echo -e "  ${marker} ${i}) ${opt}"
        ((i++))
    done

    local num
    echo -ne "  ${BOLD}Select${NC} [1-${#options[@]}]: "
    read -r num

    if [[ -n "$num" && "$num" =~ ^[0-9]+$ && "$num" -ge 1 && "$num" -le ${#options[@]} ]]; then
        eval "$varname=\"${options[$((num-1))]}\""
    elif [[ -n "$current" ]]; then
        # Keep current value if user just hits enter
        true
    else
        eval "$varname=\"${options[0]}\""
    fi
}

#===============================================================================
# Validation Functions
#===============================================================================
validate_ip() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

validate_tailscale_ip() {
    local ip="$1"
    [[ "$ip" =~ ^100\. ]]
}

validate_ssh_key() {
    local key_path="$1"
    # Expand tilde
    key_path="${key_path/#\~/$HOME}"
    [[ -f "$key_path" ]]
}

validate_cloudflare_token() {
    local token="$1"
    if ! command -v curl &>/dev/null; then
        warn "curl not found — skipping Cloudflare validation"
        return 0
    fi

    echo -ne "  ${DIM}Validating Cloudflare token...${NC}"
    local response
    response=$(curl -s --max-time 10 -H "Authorization: Bearer ${token}" \
        "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null || echo "")

    if echo "$response" | grep -q '"success"[[:space:]]*:[[:space:]]*true'; then
        echo -e "\r  ${GREEN}✓${NC} Cloudflare token is valid                     "
        # Try to show zone info
        local zones
        zones=$(curl -s --max-time 10 -H "Authorization: Bearer ${token}" \
            "https://api.cloudflare.com/client/v4/zones?per_page=5" 2>/dev/null || echo "")
        if [[ -n "$zones" ]]; then
            local zone_names
            zone_names=$(echo "$zones" | grep -o '"name":"[^"]*"' | head -3 | sed 's/"name":"//;s/"//' || true)
            if [[ -n "$zone_names" ]]; then
                hint "Zones: $zone_names"
            fi
        fi
        return 0
    else
        echo -e "\r  ${RED}✗${NC} Cloudflare token validation failed             "
        if [[ -n "$response" ]]; then
            hint "Response: $(echo "$response" | head -c 200)"
        else
            hint "No response — check network or token format"
        fi
        return 1
    fi
}

validate_tailscale_token() {
    local token="$1"
    if ! command -v curl &>/dev/null; then
        warn "curl not found — skipping Tailscale validation"
        return 0
    fi

    echo -ne "  ${DIM}Validating Tailscale token...${NC}"
    local response
    response=$(curl -sf -u "${token}:" \
        "https://api.tailscale.com/api/v2/tailnet/-/devices?fields=default" 2>/dev/null || echo "")

    if echo "$response" | grep -q '"devices"'; then
        local device_count
        device_count=$(echo "$response" | grep -o '"id"' | wc -l | tr -d ' ')
        echo -e "\r  ${GREEN}✓${NC} Tailscale token is valid (${device_count} devices)     "
        return 0
    else
        echo -e "\r  ${RED}✗${NC} Tailscale token validation failed              "
        return 1
    fi
}

validate_pi_reachable() {
    local ip="$1"
    echo -ne "  ${DIM}Pinging ${ip}...${NC}"
    if ping -c 1 -W 3 "$ip" &>/dev/null; then
        echo -e "\r  ${GREEN}✓${NC} ${ip} is reachable                           "
        return 0
    else
        echo -e "\r  ${YELLOW}⚠${NC} ${ip} is not reachable (may be offline)       "
        return 1
    fi
}

check_ssh_host_key() {
    local ip="$1"

    # Check if we have any existing host key stored for this IP
    local stored_key
    stored_key=$(ssh-keygen -F "$ip" 2>/dev/null | grep -v "^#" || true)
    if [[ -z "$stored_key" ]]; then
        # No existing host key — nothing to conflict
        return 0
    fi

    # We have a stored key. Scan the remote host for its current key.
    echo -ne "  ${DIM}Checking SSH host key for ${ip}...${NC}"
    local remote_keys
    remote_keys=$(ssh-keyscan -T 3 "$ip" 2>/dev/null || true)
    if [[ -z "$remote_keys" ]]; then
        echo -e "\r  ${DIM}Could not scan host key for ${ip} (host may be offline)${NC}    "
        return 0
    fi

    # Compare: check if any remote key type matches what we have stored
    local mismatch=false
    while IFS= read -r remote_line; do
        [[ -z "$remote_line" || "$remote_line" =~ ^# ]] && continue
        local key_type
        key_type=$(echo "$remote_line" | awk '{print $2}')
        # Check if we have a stored key of this same type
        local stored_of_type
        stored_of_type=$(ssh-keygen -F "$ip" 2>/dev/null | grep -v "^#" | grep "$key_type" || true)
        if [[ -n "$stored_of_type" ]]; then
            # We have a stored key of this type — does it match?
            local remote_key_data
            remote_key_data=$(echo "$remote_line" | awk '{print $3}')
            if ! echo "$stored_of_type" | grep -q "$remote_key_data"; then
                mismatch=true
                break
            fi
        fi
    done <<< "$remote_keys"

    if [[ "$mismatch" == "true" ]]; then
        echo -e "\r  ${YELLOW}⚠${NC} SSH host key mismatch for ${ip} (expected after SD card wipe)   "
        if confirm "Clear old SSH host key for ${ip}?" "y"; then
            ssh-keygen -R "$ip" 2>/dev/null
            # Immediately add the new key so bootstrap doesn't have to
            ssh-keyscan -T 3 "$ip" >> ~/.ssh/known_hosts 2>/dev/null
            info "Cleared old key and added new host key for ${ip}"
        else
            warn "Keeping stale host key — SSH/Ansible will fail for ${ip}"
        fi
    else
        echo -e "\r  ${GREEN}✓${NC} SSH host key for ${ip} is current                              "
    fi

    # If there's still no stored key (first time connecting), add it now
    local final_check
    final_check=$(ssh-keygen -F "$ip" 2>/dev/null | grep -v "^#" || true)
    if [[ -z "$final_check" && -n "$remote_keys" ]]; then
        echo "$remote_keys" >> ~/.ssh/known_hosts
        info "Added new host key for ${ip} to known_hosts"
    fi
}

validate_ssh_connection() {
    local ip="$1"
    local user="$2"
    local key="$3"
    key="${key/#\~/$HOME}"

    echo -ne "  ${DIM}Testing SSH to ${user}@${ip}...${NC}"
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
        -i "$key" "${user}@${ip}" "echo ok" &>/dev/null; then
        echo -e "\r  ${GREEN}✓${NC} SSH connection to ${ip} verified                "
        return 0
    else
        echo -e "\r  ${YELLOW}⚠${NC} SSH connection failed to ${ip} (key may not be deployed yet)"
        return 1
    fi
}

#===============================================================================
# Load existing .env.bootstrap if present
#===============================================================================
load_existing_env() {
    if [[ -f "$ENV_FILE" && "$RECONFIGURE" != "true" ]]; then
        info "Loading existing ${ENV_FILE##*/}"
        # Source it safely — only pick up known variables
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            # Remove leading/trailing whitespace, 'export' prefix, and quotes
            key=$(echo "$key" | xargs | sed 's/^export[[:space:]]*//')
            value=$(echo "$value" | sed "s/^['\"]//;s/['\"]$//")
            case "$key" in
                CLOUDFLARE_API_TOKEN) CLOUDFLARE_API_TOKEN="$value" ;;
                TAILSCALE_API_TOKEN)  TAILSCALE_API_TOKEN="$value" ;;
                TAILSCALE_AUTH_KEY)   TAILSCALE_AUTH_KEY="$value" ;;
                CENTRAL_TAILSCALE_IP) CENTRAL_TAILSCALE_IP="$value" ;;
                RANCHER_BOOTSTRAP_PASSWORD) RANCHER_BOOTSTRAP_PASSWORD="$value" ;;
                RANCHER_HOSTNAME)     RANCHER_HOSTNAME="$value" ;;
                PI_IP)                PI_IP="$value" ;;
                SSH_USER)             SSH_USER="$value" ;;
                SSH_KEY_PATH)         SSH_KEY_PATH="$value" ;;
                PLATFORM)             PLATFORM="$value" ;;
                MODE)                 MODE="$value" ;;
                STACK)                STACK="$value" ;;
                DOMAIN)               DOMAIN="$value" ;;
            esac
        done < "$ENV_FILE"
        echo ""
    fi
}

# Load domain from config.yaml if available
load_config_domain() {
    if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
        local cfg_domain
        cfg_domain=$(yq eval '.dns.domain // ""' "$CONFIG_FILE" 2>/dev/null || echo "")
        if [[ -n "$cfg_domain" && -z "$DOMAIN" ]]; then
            DOMAIN="$cfg_domain"
        fi
    fi
}

#===============================================================================
# Questionnaire Sections
#===============================================================================
section_platform() {
    print_section "1/7  Platform & Mode"

    echo "  Target platform:"
    select_option PLATFORM "pi" "mac" "cloud"
    info "Platform: ${PLATFORM}"

    echo ""
    echo "  Deployment mode:"
    select_option MODE "dev" "prod"
    info "Mode: ${MODE}"

    echo ""
    echo "  Orchestration stack:"
    select_option STACK "karmada" "fleet"
    info "Stack: ${STACK}"
}

section_domain() {
    print_section "2/7  Domain & DNS"

    hint "Your domain is used for Rancher, GitLab, and wildcard TLS certs."
    hint "Example: kubew.dev → rancher.kubew.dev, gitlab.kubew.dev"
    echo ""
    prompt "Domain" "${DOMAIN:-}" DOMAIN

    if [[ -n "$DOMAIN" ]]; then
        RANCHER_HOSTNAME="${RANCHER_HOSTNAME:-rancher.${DOMAIN}}"
        info "Rancher will be at: https://${RANCHER_HOSTNAME}"
        info "GitLab will be at:  https://gitlab.${DOMAIN}"
    else
        warn "No domain set — Rancher will use auto-detected LAN address"
    fi
}

section_cloudflare() {
    print_section "3/7  Cloudflare (TLS Certificates)"

    if [[ -z "$DOMAIN" ]]; then
        hint "Skipped — no domain configured"
        return
    fi

    hint "Required for Let's Encrypt wildcard certs via DNS-01 challenge."
    hint "Create at: https://dash.cloudflare.com/profile/api-tokens"
    hint "Use the 'Edit zone DNS' template. Permissions needed: Zone:DNS:Edit for ${DOMAIN}"
    hint "Expected format: starts with 'cfut_' (API Token). NOT a Global API Key (hex string)"
    echo ""
    prompt "Cloudflare API Token" "" CLOUDFLARE_API_TOKEN --secret

    if [[ -n "$CLOUDFLARE_API_TOKEN" ]]; then
        # Warn about wrong token types before hitting the API
        if [[ "$CLOUDFLARE_API_TOKEN" =~ ^[0-9a-f]{37}$ ]]; then
            warn "This looks like a Global API Key (37-char hex), not an API Token"
            warn "API Tokens start with a prefix like 'cfut_' and are created per-permission"
            hint "Create one at: https://dash.cloudflare.com/profile/api-tokens → 'Edit zone DNS' template"
        elif [[ "$CLOUDFLARE_API_TOKEN" =~ ^cfat_ ]]; then
            warn "This looks like a Cloudflare Account Token (cfat_), not a zone-scoped API Token"
            hint "Create a zone-scoped token: 'Edit zone DNS' template at the API Tokens page"
        fi
        validate_cloudflare_token "$CLOUDFLARE_API_TOKEN" || true
    else
        warn "No token set — TLS certs won't be auto-issued"
        warn "You can add this later and re-run bootstrap"
    fi
}

section_tailscale() {
    print_section "4/7  Tailscale (Mesh VPN)"

    hint "Tailscale connects your clusters over a secure mesh network."
    hint "Create an API key at: https://login.tailscale.com/admin/settings/keys"
    hint "Type: API key, Scopes: all, Expiry: 90 days"
    hint "Expected format: starts with 'tskey-api-' (API key, NOT an auth key)"
    echo ""
    prompt "Tailscale API Token" "" TAILSCALE_API_TOKEN --secret

    if [[ -n "$TAILSCALE_API_TOKEN" ]]; then
        # Warn about wrong key types
        if [[ "$TAILSCALE_API_TOKEN" =~ ^tskey-auth- ]]; then
            warn "This looks like a Tailscale Auth Key (tskey-auth-...), not an API key"
            hint "API keys start with 'tskey-api-' and are used to manage the tailnet"
            hint "Auth keys are for joining devices — enter those in the next prompt instead"
        elif [[ ! "$TAILSCALE_API_TOKEN" =~ ^tskey-api- ]]; then
            warn "Expected a Tailscale API key starting with 'tskey-api-'"
            hint "Create one at: https://login.tailscale.com/admin/settings/keys"
        fi
        validate_tailscale_token "$TAILSCALE_API_TOKEN" || true
    else
        warn "No token set — Tailscale key management won't be deployed"
        warn "Nodes can still join Tailscale manually"
    fi

    echo ""
    hint "Auth key for provisioning new nodes. Leave blank to auto-create from API key above."
    hint "If provided, expected format: starts with 'tskey-auth-'"
    prompt "Tailscale Auth Key (optional)" "" TAILSCALE_AUTH_KEY --secret

    if [[ -n "$TAILSCALE_AUTH_KEY" && ! "$TAILSCALE_AUTH_KEY" =~ ^tskey-auth- ]]; then
        warn "Expected a Tailscale auth key starting with 'tskey-auth-'"
        if [[ "$TAILSCALE_AUTH_KEY" =~ ^tskey-api- ]]; then
            hint "This looks like an API key — it belongs in the API Token field above"
        fi
    fi

    echo ""
    hint "Central node's Tailscale IP (100.x.x.x) for DNS entries."
    hint "Find with: tailscale ip -4  (on the central node)"
    prompt "Central Tailscale IP" "${CENTRAL_TAILSCALE_IP:-}" CENTRAL_TAILSCALE_IP

    if [[ -n "$CENTRAL_TAILSCALE_IP" ]]; then
        if validate_tailscale_ip "$CENTRAL_TAILSCALE_IP"; then
            info "Tailscale IP: ${CENTRAL_TAILSCALE_IP}"
        else
            warn "${CENTRAL_TAILSCALE_IP} doesn't look like a Tailscale IP (expected 100.x.x.x)"
        fi
    fi
}

section_pi() {
    print_section "5/7  Pi Hardware"

    if [[ "$PLATFORM" != "pi" ]]; then
        hint "Skipped — not targeting Pi"
        return
    fi

    hint "Central Pi's LAN IP address (ethernet recommended)."
    hint "Discovery: ping raspberrypi.local, or check router DHCP leases"
    echo ""
    prompt "Central Pi IP" "${PI_IP:-}" PI_IP

    if [[ -n "$PI_IP" ]]; then
        if validate_ip "$PI_IP"; then
            validate_pi_reachable "$PI_IP" || true
            # Check for stale SSH host keys (common after wiping SD cards)
            check_ssh_host_key "$PI_IP"
        else
            err "Invalid IP format: ${PI_IP}"
        fi
    else
        err "Pi IP is required for Pi platform bootstrap"
    fi

    echo ""
    prompt "SSH User" "${SSH_USER:-admin}" SSH_USER
    prompt "SSH Key Path" "${SSH_KEY_PATH:-~/.ssh/id_ed25519}" SSH_KEY_PATH

    if validate_ssh_key "$SSH_KEY_PATH"; then
        info "SSH key found: ${SSH_KEY_PATH}"
        if [[ -n "$PI_IP" ]]; then
            validate_ssh_connection "$PI_IP" "$SSH_USER" "$SSH_KEY_PATH" || true
        fi
    else
        warn "SSH key not found at ${SSH_KEY_PATH}"
        warn "Generate one with: ssh-keygen -t ed25519"
    fi

    # Also check edge Pi IPs from inventory — host keys + SSH connection
    local inv_file="${REPO_ROOT}/pi-setup/inventory.ini"
    if [[ -f "$inv_file" ]]; then
        local edge_ips
        edge_ips=$(grep -E '^\s*pi-edge' "$inv_file" | grep -o 'ansible_host=[^ ]*' | cut -d= -f2 || true)
        for edge_ip in $edge_ips; do
            if [[ -n "$edge_ip" && "$edge_ip" != "$PI_IP" ]]; then
                check_ssh_host_key "$edge_ip"
                if validate_ssh_key "$SSH_KEY_PATH"; then
                    validate_ssh_connection "$edge_ip" "$SSH_USER" "$SSH_KEY_PATH" || true
                fi
            fi
        done
    fi
}

section_rancher() {
    print_section "6/7  Rancher"

    hint "Bootstrap password for initial Rancher admin login."
    hint "Leave blank to auto-generate a secure password."
    echo ""

    if [[ -z "$RANCHER_BOOTSTRAP_PASSWORD" ]]; then
        if confirm "Auto-generate Rancher password?" "y"; then
            RANCHER_BOOTSTRAP_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 24)
            info "Generated password: ${RANCHER_BOOTSTRAP_PASSWORD}"
            warn "Save this! It won't be shown again after bootstrap."
        else
            prompt "Rancher Bootstrap Password" "" RANCHER_BOOTSTRAP_PASSWORD --secret
        fi
    else
        if confirm "Keep existing Rancher password?" "y"; then
            info "Keeping existing password"
        else
            prompt "New Rancher Bootstrap Password" "" RANCHER_BOOTSTRAP_PASSWORD --secret
        fi
    fi

    echo ""
    if [[ -n "$DOMAIN" ]]; then
        prompt "Rancher Hostname" "${RANCHER_HOSTNAME:-rancher.${DOMAIN}}" RANCHER_HOSTNAME
    else
        prompt "Rancher Hostname" "${RANCHER_HOSTNAME:-}" RANCHER_HOSTNAME
    fi
}

section_review() {
    print_section "7/7  Review"

    echo -e "  ${BOLD}Platform:${NC}       ${PLATFORM}"
    echo -e "  ${BOLD}Mode:${NC}           ${MODE}"
    echo -e "  ${BOLD}Stack:${NC}          ${STACK}"
    echo ""
    echo -e "  ${BOLD}Domain:${NC}         ${DOMAIN:-${DIM}(none)${NC}}"
    echo -e "  ${BOLD}Rancher:${NC}        ${RANCHER_HOSTNAME:-${DIM}(auto-detect)${NC}}"
    echo ""

    if [[ -n "$CLOUDFLARE_API_TOKEN" ]]; then
        echo -e "  ${BOLD}Cloudflare:${NC}     ${GREEN}configured${NC}"
    else
        echo -e "  ${BOLD}Cloudflare:${NC}     ${YELLOW}not set${NC}"
    fi

    if [[ -n "$TAILSCALE_API_TOKEN" ]]; then
        echo -e "  ${BOLD}Tailscale API:${NC}  ${GREEN}configured${NC}"
    else
        echo -e "  ${BOLD}Tailscale API:${NC}  ${YELLOW}not set${NC}"
    fi

    if [[ -n "$TAILSCALE_AUTH_KEY" ]]; then
        echo -e "  ${BOLD}Tailscale Auth:${NC} ${GREEN}configured${NC}"
    else
        echo -e "  ${BOLD}Tailscale Auth:${NC} ${DIM}(will auto-create)${NC}"
    fi

    echo -e "  ${BOLD}Central TS IP:${NC}  ${CENTRAL_TAILSCALE_IP:-${DIM}(not set)${NC}}"

    if [[ "$PLATFORM" == "pi" ]]; then
        echo ""
        echo -e "  ${BOLD}Pi IP:${NC}          ${PI_IP:-${RED}NOT SET${NC}}"
        echo -e "  ${BOLD}SSH User:${NC}       ${SSH_USER:-admin}"
        echo -e "  ${BOLD}SSH Key:${NC}        ${SSH_KEY_PATH:-~/.ssh/id_ed25519}"
    fi

    echo ""
}

#===============================================================================
# Generate .env.bootstrap
#===============================================================================
generate_env_file() {
    local tmpfile
    tmpfile=$(mktemp)

    cat > "$tmpfile" << ENVEOF
# kube-world Bootstrap Configuration
# Generated by setup.sh at $(date '+%Y-%m-%d %H:%M:%S')
#
# Usage:
#   source .env.bootstrap && ./bootstrap.sh --platform ${PLATFORM} --stack ${STACK}
#
# Variables use 'export' so they propagate to child processes (bootstrap.sh,
# ansible-playbook, etc.). Without this, values set here are invisible to
# anything bootstrap.sh spawns.
#
# To reconfigure: ./scripts/setup.sh --reconfigure

# Platform & Mode
export PLATFORM=${PLATFORM}
export MODE=${MODE}
export STACK=${STACK}

# Domain
export DOMAIN=${DOMAIN}

# Cloudflare (DNS-01 cert challenges)
export CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN}

# Tailscale (mesh VPN)
export TAILSCALE_API_TOKEN=${TAILSCALE_API_TOKEN}
export TAILSCALE_AUTH_KEY=${TAILSCALE_AUTH_KEY}
export CENTRAL_TAILSCALE_IP=${CENTRAL_TAILSCALE_IP}

# Rancher
export RANCHER_BOOTSTRAP_PASSWORD=${RANCHER_BOOTSTRAP_PASSWORD}
export RANCHER_HOSTNAME=${RANCHER_HOSTNAME}
ENVEOF

    # Add Pi-specific vars
    if [[ "$PLATFORM" == "pi" ]]; then
        cat >> "$tmpfile" << PIEOF

# Pi Hardware
export PI_IP=${PI_IP}
export SSH_USER=${SSH_USER}
export SSH_KEY_PATH=${SSH_KEY_PATH}
PIEOF
    fi

    mv "$tmpfile" "$ENV_FILE"
    chmod 600 "$ENV_FILE"

    echo ""
    info "Generated ${ENV_FILE}"
    info "File permissions set to 600 (owner-only)"
}

# Update config.yaml domain if yq is available
update_config_yaml() {
    if [[ -z "$DOMAIN" || ! -f "$CONFIG_FILE" ]]; then
        return
    fi
    if ! command -v yq &>/dev/null; then
        hint "Install yq to auto-update config.yaml with domain settings"
        return
    fi

    local current_domain
    current_domain=$(yq eval '.dns.domain // ""' "$CONFIG_FILE" 2>/dev/null || echo "")

    if [[ "$current_domain" != "$DOMAIN" ]]; then
        yq eval ".dns.domain = \"${DOMAIN}\"" -i "$CONFIG_FILE"
        info "Updated config.yaml dns.domain → ${DOMAIN}"
    fi
}

# Update inventory.ini with Pi IP if different
update_inventory() {
    if [[ "$PLATFORM" != "pi" || -z "$PI_IP" ]]; then
        return
    fi

    local inv_file="${REPO_ROOT}/pi-setup/inventory.ini"
    if [[ ! -f "$inv_file" ]]; then
        return
    fi

    local current_ip
    current_ip=$(grep "^pi-central" "$inv_file" | grep -o 'ansible_host=[^ ]*' | cut -d= -f2 || echo "")

    if [[ -n "$current_ip" && "$current_ip" != "$PI_IP" ]]; then
        if confirm "Update inventory.ini pi-central IP from ${current_ip} to ${PI_IP}?" "y"; then
            sed -i.bak "s/ansible_host=${current_ip}/ansible_host=${PI_IP}/" "$inv_file"
            rm -f "${inv_file}.bak"
            info "Updated inventory.ini pi-central → ${PI_IP}"
        fi
    fi

    # Update SSH key path if different from default
    local current_key
    current_key=$(grep "ansible_ssh_private_key_file" "$inv_file" | head -1 | cut -d= -f2 || echo "")
    if [[ -n "$SSH_KEY_PATH" && "$current_key" != "$SSH_KEY_PATH" ]]; then
        sed -i.bak "s|ansible_ssh_private_key_file=.*|ansible_ssh_private_key_file=${SSH_KEY_PATH}|" "$inv_file"
        rm -f "${inv_file}.bak"
        info "Updated inventory.ini SSH key → ${SSH_KEY_PATH}"
    fi
}

#===============================================================================
# Validate existing config (--validate mode)
#===============================================================================
run_validation() {
    print_header
    print_section "Validating existing configuration"

    if [[ ! -f "$ENV_FILE" ]]; then
        err "No .env.bootstrap found. Run setup.sh without --validate first."
        exit 1
    fi

    load_existing_env

    local errors=0

    # Check required fields
    if [[ -z "$PLATFORM" ]]; then
        err "PLATFORM not set"
        ((errors++))
    else
        info "Platform: ${PLATFORM}"
    fi

    if [[ "$PLATFORM" == "pi" && -z "$PI_IP" ]]; then
        err "PI_IP required for Pi platform"
        ((errors++))
    elif [[ "$PLATFORM" == "pi" ]]; then
        validate_pi_reachable "$PI_IP" || ((errors++))
    fi

    if [[ -n "$CLOUDFLARE_API_TOKEN" ]]; then
        validate_cloudflare_token "$CLOUDFLARE_API_TOKEN" || ((errors++))
    else
        warn "CLOUDFLARE_API_TOKEN not set — TLS certs won't be auto-issued"
    fi

    if [[ -n "$TAILSCALE_API_TOKEN" ]]; then
        validate_tailscale_token "$TAILSCALE_API_TOKEN" || ((errors++))
    else
        warn "TAILSCALE_API_TOKEN not set — key management disabled"
    fi

    if [[ -n "$SSH_KEY_PATH" ]]; then
        if validate_ssh_key "$SSH_KEY_PATH"; then
            info "SSH key exists: ${SSH_KEY_PATH}"
        else
            err "SSH key not found: ${SSH_KEY_PATH}"
            ((errors++))
        fi
    fi

    echo ""
    if [[ "$errors" -eq 0 ]]; then
        info "All checks passed! Ready to bootstrap."
        echo ""
        echo -e "  Run: ${BOLD}source .env.bootstrap && ./bootstrap.sh --platform ${PLATFORM} --stack ${STACK}${NC}"
    else
        err "${errors} check(s) failed. Fix issues and re-run validation."
        exit 1
    fi
}

#===============================================================================
# Main
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --validate)
                VALIDATE_ONLY=true
                shift
                ;;
            --reconfigure)
                RECONFIGURE=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [--validate | --reconfigure | --help]"
                echo ""
                echo "  (no args)      Interactive setup wizard"
                echo "  --validate     Validate existing .env.bootstrap"
                echo "  --reconfigure  Start fresh, ignoring existing values"
                echo "  --help         Show this help"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                exit 1
                ;;
        esac
    done
}

main() {
    parse_args "$@"

    if [[ "$VALIDATE_ONLY" == "true" ]]; then
        run_validation
        exit 0
    fi

    print_header

    # Load existing values as defaults
    load_existing_env
    load_config_domain

    # Run questionnaire sections
    section_platform
    section_domain
    section_cloudflare
    section_tailscale
    section_pi
    section_rancher
    section_review

    # Confirm and generate
    if confirm "Generate .env.bootstrap with these settings?" "y"; then
        generate_env_file
        update_config_yaml
        update_inventory

        echo ""
        echo -e "${GREEN}${BOLD}Setup complete!${NC}"
        echo ""
        echo "  To bootstrap:"
        echo -e "    ${BOLD}source .env.bootstrap && ./bootstrap.sh --platform ${PLATFORM} --stack ${STACK} --verbose${NC}"
        echo ""
        echo "  To validate configuration:"
        echo -e "    ${BOLD}./scripts/setup.sh --validate${NC}"
        echo ""
        echo "  To reconfigure:"
        echo -e "    ${BOLD}./scripts/setup.sh --reconfigure${NC}"
        echo ""
    else
        warn "Aborted — no files were changed."
        exit 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
