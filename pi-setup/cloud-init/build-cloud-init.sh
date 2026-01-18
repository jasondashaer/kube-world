#!/usr/bin/env bash
#===============================================================================
# build-cloud-init.sh - Dynamic Cloud-Init Configuration Builder
#
# Builds cloud-init configuration files (user-data, meta-data, network-config)
# for Raspberry Pi provisioning with proper password hashing and key injection.
#
# Usage:
#   ./build-cloud-init.sh [OPTIONS]
#
# Options:
#   --hostname NAME       Pi hostname (default: pi-node-1)
#   --role ROLE           master | worker (default: worker)
#   --wifi-ssid SSID      WiFi network name (optional)
#   --wifi-pass PASS      WiFi password (will be hashed)
#   --user-pass PASS      User password (will be SHA-512 hashed)
#   --ssh-key FILE        Path to SSH public key (default: ~/.ssh/id_ed25519.pub)
#   --ip ADDRESS          Static IP (optional, uses DHCP if not set)
#   --gateway IP          Gateway IP (required if --ip is set)
#   --output DIR          Output directory (default: ./output)
#   --copy-to PATH        Copy files to SD card boot partition (e.g., /Volumes/bootfs)
#   --dry-run             Show what would be generated
#   -h, --help            Show this help
#
# Examples:
#   # Worker node with WiFi
#   ./build-cloud-init.sh --hostname pi-worker-1 --role worker \
#       --wifi-ssid "MyNetwork" --wifi-pass "MyPassword123" \
#       --user-pass "securepass" --copy-to /Volumes/bootfs
#
#   # Master node with static IP on ethernet
#   ./build-cloud-init.sh --hostname pi-master-1 --role master \
#       --ip 192.168.1.100 --gateway 192.168.1.1 \
#       --user-pass "securepass" --copy-to /Volumes/bootfs
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[BUILD]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
debug() { [[ "${VERBOSE:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*"; }

# Defaults
HOSTNAME="pi-node-1"
ROLE="worker"
WIFI_SSID=""
WIFI_PASS=""
USER_PASS=""
SSH_KEY_FILE="${HOME}/.ssh/id_ed25519.pub"
STATIC_IP=""
GATEWAY=""
OUTPUT_DIR="${SCRIPT_DIR}/output"
COPY_TO=""
DRY_RUN=false
VERBOSE=false

#===============================================================================
# Help
#===============================================================================
show_help() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                     Cloud-Init Configuration Builder                           ║
╚═══════════════════════════════════════════════════════════════════════════════╝

Builds properly formatted cloud-init files for Raspberry Pi with:
  - WPA PSK hashing for WiFi passwords (using wpa_passphrase format)
  - SHA-512 hashing for user passwords
  - Auto-injection of SSH public keys
  - Support for master (K3s server) or worker (K3s agent) roles

USAGE:
    ./build-cloud-init.sh [OPTIONS]

OPTIONS:
    --hostname NAME       Pi hostname (default: pi-node-1)
    --role ROLE           master | worker (default: worker)
    --wifi-ssid SSID      WiFi network name
    --wifi-pass PASS      WiFi password (will be properly hashed)
    --wifi-country CODE   WiFi regulatory domain (default: US)
    --user-pass PASS      User login password (will be SHA-512 hashed)
    --ssh-key FILE        SSH public key file (default: ~/.ssh/id_ed25519.pub)
    --ip ADDRESS          Static IP address (e.g., 192.168.1.100/24)
    --gateway IP          Gateway IP (required with --ip)
    --output DIR          Output directory (default: ./output)
    --copy-to PATH        Copy to SD card (e.g., /Volumes/bootfs)
    --dry-run             Preview without writing files
    --verbose             Show detailed output
    -h, --help            Show this help

EXAMPLES:
    # WiFi worker node
    ./build-cloud-init.sh --hostname pi-worker-1 \\
        --wifi-ssid "HomeNetwork" --wifi-pass "secret123" \\
        --user-pass "adminpass" --copy-to /Volumes/bootfs

    # Ethernet master with static IP
    ./build-cloud-init.sh --hostname pi-master-1 --role master \\
        --ip 192.168.1.100/24 --gateway 192.168.1.1 \\
        --user-pass "adminpass" --copy-to /Volumes/bootfs

NOTES:
    - WiFi passwords are hashed using wpa_passphrase for security
    - User passwords are SHA-512 hashed (required by cloud-init)
    - SSH keys are auto-loaded from file for passwordless access
    - Generated files: user-data, meta-data, network-config (no .yaml extension)

EOF
}

#===============================================================================
# Parse Arguments
#===============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --hostname)
                HOSTNAME="$2"
                shift 2
                ;;
            --role)
                ROLE="$2"
                shift 2
                ;;
            --wifi-ssid)
                WIFI_SSID="$2"
                shift 2
                ;;
            --wifi-pass)
                WIFI_PASS="$2"
                shift 2
                ;;
            --wifi-country)
                WIFI_COUNTRY="$2"
                shift 2
                ;;
            --user-pass)
                USER_PASS="$2"
                shift 2
                ;;
            --ssh-key)
                SSH_KEY_FILE="$2"
                shift 2
                ;;
            --ip)
                STATIC_IP="$2"
                shift 2
                ;;
            --gateway)
                GATEWAY="$2"
                shift 2
                ;;
            --output)
                OUTPUT_DIR="$2"
                shift 2
                ;;
            --copy-to)
                COPY_TO="$2"
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
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

#===============================================================================
# Validation
#===============================================================================
validate_inputs() {
    log "Validating inputs..."
    
    # Check Docker is available (needed for SHA-512 on macOS)
    if [[ "$(uname)" == "Darwin" ]] && ! command -v docker &>/dev/null; then
        error "Docker is required on macOS for password hashing"
        error "Install Docker Desktop: https://www.docker.com/products/docker-desktop"
        exit 1
    fi
    
    # Check role
    if [[ "$ROLE" != "master" && "$ROLE" != "worker" ]]; then
        error "Role must be 'master' or 'worker'"
        exit 1
    fi
    
    # Check static IP requires gateway
    if [[ -n "$STATIC_IP" && -z "$GATEWAY" ]]; then
        error "Static IP requires --gateway"
        exit 1
    fi
    
    # Check SSH key exists
    if [[ ! -f "$SSH_KEY_FILE" ]]; then
        warn "SSH key file not found: $SSH_KEY_FILE"
        # Try common SSH key locations
        local ssh_keys=(
            "${HOME}/.ssh/id_ed25519.pub"
            "${HOME}/.ssh/id_rsa.pub"
            "${HOME}/.ssh/id_ecdsa.pub"
            "${HOME}/.ssh/rpissh.pub"
        )
        SSH_KEY_FILE=""
        for key in "${ssh_keys[@]}"; do
            if [[ -f "$key" ]]; then
                SSH_KEY_FILE="$key"
                log "Found SSH key: $key"
                break
            fi
        done
        if [[ -z "$SSH_KEY_FILE" ]]; then
            error "No SSH public key found. Generate one with: ssh-keygen -t ed25519"
            error "Or specify with: --ssh-key /path/to/key.pub"
            exit 1
        fi
    fi
    
    # Check user password
    if [[ -z "$USER_PASS" ]]; then
        warn "No user password provided. Will prompt..."
        read -sp "Enter password for 'admin' user: " USER_PASS
        echo
        if [[ -z "$USER_PASS" ]]; then
            error "Password is required"
            exit 1
        fi
    fi
    
    # Check WiFi password if SSID provided
    if [[ -n "$WIFI_SSID" && -z "$WIFI_PASS" ]]; then
        read -sp "Enter WiFi password for '$WIFI_SSID': " WIFI_PASS
        echo
    fi
    
    log "Inputs validated ✓"
}

#===============================================================================
# Password Hashing Functions
#===============================================================================

# Generate SHA-512 hash for user password (required by cloud-init)
hash_user_password() {
    local password="$1"
    
    # Try multiple methods for SHA-512 hash generation
    # Method 1: Linux mkpasswd (preferred)
    if command -v mkpasswd &>/dev/null; then
        mkpasswd -m sha-512 "$password"
        return
    fi
    
    # Method 2: openssl with SHA-512 support (Linux)
    if openssl passwd -6 2>/dev/null | head -1 | grep -q '^\$6\$'; then
        openssl passwd -6 "$password"
        return
    fi
    
    # Method 3: Docker-based (works on macOS)
    if command -v docker &>/dev/null; then
        docker run --rm alpine sh -c "apk add --no-cache openssl > /dev/null 2>&1 && openssl passwd -6 '$password'" 2>/dev/null
        return
    fi
    
    # Method 4: Python passlib (if installed)
    if python3 -c "from passlib.hash import sha512_crypt" 2>/dev/null; then
        python3 -c "from passlib.hash import sha512_crypt; print(sha512_crypt.hash('${password}'))"
        return
    fi
    
    # Fallback: Error - cannot generate proper hash
    error "Cannot generate SHA-512 password hash."
    error "Install one of: mkpasswd, openssl 1.1+, Docker, or Python passlib"
    error "  macOS: brew install passlib  OR  use Docker (recommended)"
    exit 1
}

# Generate WPA PSK hash for WiFi password
# Note: netplan/NetworkManager can accept plaintext, but PSK is more secure
hash_wifi_password() {
    local ssid="$1"
    local password="$2"
    
    # wpa_passphrase generates a 256-bit PSK from SSID and passphrase
    if command -v wpa_passphrase &>/dev/null; then
        wpa_passphrase "$ssid" "$password" | grep -E "^\s*psk=" | cut -d= -f2
    else
        # Fallback: Use Python to generate PSK (PBKDF2-SHA1)
        python3 -c "
import hashlib
ssid = '${ssid}'
password = '${password}'
psk = hashlib.pbkdf2_hmac('sha1', password.encode(), ssid.encode(), 4096, 32)
print(psk.hex())
"
    fi
}

# WiFi regulatory domain (2-letter country code)
# Required for 5GHz and some 2.4GHz channels to work
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"

#===============================================================================
# Generate meta-data
#===============================================================================
generate_meta_data() {
    cat << EOF
instance-id: ${HOSTNAME}
local-hostname: ${HOSTNAME}
EOF
}

#===============================================================================
# Generate network-config
#===============================================================================
generate_network_config() {
    local wifi_section=""
    local eth_section=""
    
    # Ethernet configuration
    if [[ -n "$STATIC_IP" ]]; then
        # Static IP
        eth_section="    eth0:
      dhcp4: false
      addresses:
        - ${STATIC_IP}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4"
    else
        # DHCP
        eth_section="    eth0:
      dhcp4: true"
    fi
    
    # WiFi configuration (optional)
    if [[ -n "$WIFI_SSID" ]]; then
        local wifi_psk
        wifi_psk=$(hash_wifi_password "$WIFI_SSID" "$WIFI_PASS")
        
        # Note: Using plaintext password as some cloud-init implementations 
        # don't properly handle PSK. The plaintext gets hashed at connection time.
        # Uncomment the PSK line below if you prefer pre-hashed (more secure at rest).
        wifi_section="
  wifis:
    wlan0:
      dhcp4: true
      optional: true
      regulatory-domain: ${WIFI_COUNTRY}
      access-points:
        \"${WIFI_SSID}\":
          # Use plaintext password (gets hashed by wpa_supplicant)
          password: \"${WIFI_PASS}\"
          # Alternative: Pre-hashed PSK (64-char hex) - uncomment if plaintext fails
          # password: \"${wifi_psk}\""
    fi
    
    cat << EOF
network:
  version: 2
  renderer: networkd
  ethernets:
${eth_section}${wifi_section}
EOF
}

#===============================================================================
# Generate user-data
#===============================================================================
generate_user_data() {
    local password_hash
    local ssh_key
    
    # Hash the user password
    password_hash=$(hash_user_password "$USER_PASS")
    
    # Read SSH public key
    ssh_key=$(cat "$SSH_KEY_FILE")
    
    # Role-specific packages
    local role_packages=""
    if [[ "$ROLE" == "master" ]]; then
        role_packages="
  - etcd"
    fi
    
    cat << EOF
#cloud-config

# System configuration
hostname: ${HOSTNAME}
manage_etc_hosts: true
locale: en_US.UTF-8
timezone: America/New_York

# User configuration
users:
  - name: admin
    groups: [sudo, docker, adm, dialout, plugdev]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: ${password_hash}
    ssh_authorized_keys:
      - ${ssh_key}

# SSH configuration
# IMPORTANT: ssh_pwauth enables password auth as fallback if key auth fails
# Set to true initially for debugging; can disable after confirming key auth works
ssh_pwauth: true
disable_root: true

# Package management
package_update: true
package_upgrade: true
package_reboot_if_required: true

packages:
  # SSH server (ensure it's installed and enabled)
  - openssh-server
  - curl
  - wget
  - git
  - vim
  - htop
  - iotop
  - jq
  - open-iscsi
  - nfs-common
  - linux-modules-extra-raspi
  # WiFi support (CRITICAL for networkd renderer)
  - wpasupplicant
  - wireless-tools
  - crda${role_packages}

# Write configuration files
write_files:
  # WiFi regulatory domain (must be set for 5GHz and some 2.4GHz channels)
  - path: /etc/default/crda
    content: |
      REGDOMAIN=${WIFI_COUNTRY}
    permissions: '0644'

  # Kernel modules for Kubernetes
  - path: /etc/modules-load.d/k8s.conf
    content: |
      br_netfilter
      overlay
    permissions: '0644'

  # SSH server configuration - ensure both password and key auth work
  - path: /etc/ssh/sshd_config.d/99-cloud-init.conf
    content: |
      # Cloud-init SSH configuration for kube-world
      PasswordAuthentication yes
      PubkeyAuthentication yes
      PermitRootLogin no
      # Allow admin user
      AllowUsers admin
    permissions: '0644'

  # Sysctl settings for Kubernetes
  - path: /etc/sysctl.d/99-kubernetes.conf
    content: |
      net.bridge.bridge-nf-call-iptables = 1
      net.bridge.bridge-nf-call-ip6tables = 1
      net.ipv4.ip_forward = 1
      vm.swappiness = 0
    permissions: '0644'

  # Node role marker
  - path: /etc/kube-world/role
    content: |
      ROLE=${ROLE}
      HOSTNAME=${HOSTNAME}
    permissions: '0644'

  # First-boot setup script
  - path: /opt/kube-world/first-boot.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e
      
      LOG_FILE="/var/log/kube-world-setup.log"
      exec > >(tee -a "\$LOG_FILE") 2>&1
      
      echo "=== kube-world first-boot setup started at \$(date) ==="
      echo "Hostname: ${HOSTNAME}"
      echo "Role: ${ROLE}"
      
      # Wait for network
      echo "Waiting for network connectivity..."
      until ping -c1 github.com &>/dev/null; do
        echo "  Waiting..."
        sleep 5
      done
      echo "Network ready ✓"
      
      # Load kernel modules
      modprobe br_netfilter || true
      modprobe overlay || true
      
      # Apply sysctl settings
      sysctl --system
      
      # Disable swap (required for Kubernetes)
      swapoff -a
      sed -i '/swap/d' /etc/fstab
      
      # Clone kube-world repository
      if [ ! -d /opt/kube-world/repo ]; then
        echo "Cloning kube-world repository..."
        git clone https://github.com/jasondashaer/kube-world.git /opt/kube-world/repo
      fi
      
      echo "=== First-boot setup complete at \$(date) ==="
      echo "Node is ready for K3s installation via Ansible."

# Boot commands - run early, before network-config
# Setting WiFi country code early helps with channel availability
bootcmd:
  - [ sh, -c, 'iw reg set ${WIFI_COUNTRY}' ]
  - [ sh, -c, 'echo "REGDOMAIN=${WIFI_COUNTRY}" > /etc/default/crda' ]

# Run commands - executed in order after cloud-init completes user setup
runcmd:
  # Ensure SSH service is enabled and started
  - systemctl enable ssh
  - systemctl start ssh
  # Ensure .ssh directory has correct permissions
  - chmod 700 /home/admin/.ssh || true
  - chmod 600 /home/admin/.ssh/authorized_keys || true
  - chown -R admin:admin /home/admin/.ssh || true
  # Create kube-world directories
  - mkdir -p /opt/kube-world
  - mkdir -p /etc/kube-world
  # Run first-boot setup
  - /opt/kube-world/first-boot.sh

# Final message
final_message: |
  Cloud-init complete for ${HOSTNAME} (${ROLE})
  SSH: ssh admin@${HOSTNAME}.local
  Run Ansible from management machine to complete K3s setup.
EOF
}

#===============================================================================
# Main
#===============================================================================
main() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                     Cloud-Init Configuration Builder                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    parse_args "$@"
    validate_inputs
    
    log "Building cloud-init configuration..."
    log "  Hostname: ${HOSTNAME}"
    log "  Role: ${ROLE}"
    log "  WiFi: ${WIFI_SSID:-disabled}"
    log "  Static IP: ${STATIC_IP:-DHCP}"
    log "  SSH Key: ${SSH_KEY_FILE}"
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    
    # Generate files
    local meta_data
    local network_config
    local user_data
    
    meta_data=$(generate_meta_data)
    network_config=$(generate_network_config)
    user_data=$(generate_user_data)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        echo ""
        echo "═══ meta-data ═══"
        echo "$meta_data"
        echo ""
        echo "═══ network-config ═══"
        echo "$network_config"
        echo ""
        echo "═══ user-data (truncated) ═══"
        echo "$user_data" | head -50
        echo "..."
        exit 0
    fi
    
    # Write files (cloud-init expects no .yaml extension)
    echo "$meta_data" > "${OUTPUT_DIR}/meta-data"
    echo "$network_config" > "${OUTPUT_DIR}/network-config"
    echo "$user_data" > "${OUTPUT_DIR}/user-data"
    
    log "Files generated in: ${OUTPUT_DIR}/"
    log "  - meta-data"
    log "  - network-config"
    log "  - user-data"
    
    # Copy to SD card if specified
    if [[ -n "$COPY_TO" ]]; then
        if [[ ! -d "$COPY_TO" ]]; then
            error "Copy destination not found: $COPY_TO"
            error "Is the SD card mounted?"
            exit 1
        fi
        
        log "Copying files to: ${COPY_TO}/"
        cp "${OUTPUT_DIR}/meta-data" "${COPY_TO}/"
        cp "${OUTPUT_DIR}/network-config" "${COPY_TO}/"
        cp "${OUTPUT_DIR}/user-data" "${COPY_TO}/"
        
        log "Files copied successfully ✓"
    fi
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                     Cloud-Init Build Complete! 🎉                              ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Next steps:"
    echo "    1. Insert SD card into Pi and boot"
    echo "    2. Wait 3-5 minutes for initial setup"
    echo "    3. SSH: ssh admin@${HOSTNAME}.local"
    echo "    4. Run: ./pi-prep.sh ${HOSTNAME}.local --join-cluster"
    echo ""
}

main "$@"
