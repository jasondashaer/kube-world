#!/usr/bin/env bash
#===============================================================================
# pi-prep.sh - Raspberry Pi 5 Preparation Script
# 
# Prepares a Raspberry Pi 5 for joining the kube-world cluster.
# Can be run from Mac (management machine) or directly on Pi.
#
# Usage:
#   ./pi-prep.sh <PI_IP_OR_HOSTNAME> [OPTIONS]
#
# Options:
#   --new-pi          First-time setup (includes flashing instructions)
#   --join-cluster    Join the Pi to existing cluster
#   --wifi-only       Configure WiFi without cluster join
#   --dry-run         Show what would be done
#   --verbose         Enable verbose output
#
# Prerequisites:
#   - SSH access to Pi (password or key-based)
#   - Pi connected to same network as management machine
#   - For new Pi: SD card flashed with Raspberry Pi OS Lite (64-bit)
#===============================================================================
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PI_USER="${PI_USER:-admin}"
K3S_VERSION="${K3S_VERSION:-v1.29.0+k3s1}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[PI-PREP]${NC} $*"; }
warn() { echo -e "${YELLOW}[PI-PREP]${NC} $*"; }
error() { echo -e "${RED}[PI-PREP]${NC} $*" >&2; }
debug() { [[ "${VERBOSE:-false}" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $*"; }

#===============================================================================
# Display Help
#===============================================================================
show_help() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                     Pi Preparation Script for kube-world                       ║
╚═══════════════════════════════════════════════════════════════════════════════╝

USAGE:
    ./pi-prep.sh <PI_IP_OR_HOSTNAME> [OPTIONS]

EXAMPLES:
    # Prep a new Pi (shows flashing instructions first)
    ./pi-prep.sh 192.168.1.100 --new-pi --verbose

    # Join existing Pi to cluster
    ./pi-prep.sh pi5-master-1.local --join-cluster

    # Just configure WiFi
    ./pi-prep.sh 192.168.1.100 --wifi-only

OPTIONS:
    --new-pi          Show SD card flashing instructions, then configure
    --join-cluster    Install K3s and join to management cluster
    --wifi-only       Only configure WiFi (for headless setup)
    --dry-run         Preview actions without executing
    --verbose         Show detailed output
    -h, --help        Show this help message

PREREQUISITES:
    1. Pi must be running Raspberry Pi OS Lite (64-bit) - ARM64
    2. SSH must be enabled (done via Imager or cloud-init)
    3. Pi must be on the same network as your Mac
    4. For new Pi: Have an SD card ready to flash

FOR NEW PI SETUP:
    1. Download Raspberry Pi Imager: https://www.raspberrypi.com/software/
    2. Select: Raspberry Pi OS Lite (64-bit)
    3. Click gear icon to configure:
       - Hostname: pi5-master-1
       - Enable SSH: Yes
       - Username: admin
       - Password: (your choice)
       - WiFi: (optional, can configure later)
    4. Flash and boot the Pi
    5. Run this script with --new-pi flag

EOF
}

#===============================================================================
# Check Prerequisites
#===============================================================================
check_prereqs() {
    log "Checking prerequisites..."
    
    # Check for required tools
    local missing=()
    for cmd in ssh scp ansible-playbook; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        error "Missing required tools: ${missing[*]}"
        error "Install with: brew install ${missing[*]}"
        exit 1
    fi
    
    log "Prerequisites OK ✓"
}

#===============================================================================
# Test SSH Connectivity (with retry)
#===============================================================================
test_ssh() {
    local pi_host="$1"
    local max_attempts="${2:-5}"
    local interval="${3:-10}"
    
    log "Testing SSH connection to ${PI_USER}@${pi_host}..."
    
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if ssh -o ConnectTimeout=10 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${PI_USER}@${pi_host}" "echo 'SSH OK'" &>/dev/null; then
            log "SSH connection successful ✓"
            return 0
        fi
        
        if [[ $attempt -lt $max_attempts ]]; then
            warn "SSH attempt ${attempt}/${max_attempts} failed, retrying in ${interval}s..."
            sleep "$interval"
        fi
        attempt=$((attempt + 1))
    done
    
    # Final attempt with password prompt
    warn "Key-based SSH failed. Trying with password..."
    if ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "${PI_USER}@${pi_host}" "echo 'SSH OK'" 2>/dev/null; then
        log "SSH with password successful ✓"
        warn "Consider setting up SSH key authentication for passwordless access"
        return 0
    fi
    
    error "Cannot connect to Pi via SSH after ${max_attempts} attempts"
    error "Ensure Pi is running and SSH is enabled"
    return 1
}

#===============================================================================
# Configure WiFi
#===============================================================================
configure_wifi() {
    local pi_host="$1"
    log "Configuring WiFi on Pi..."
    
    # Read WiFi config from config.yaml if available
    local wifi_ssid=""
    local wifi_pass=""
    
    if [[ -f "${REPO_ROOT}/config.yaml" ]]; then
        # Try to read from config (simplified - assumes unencrypted)
        wifi_ssid=$(grep -A1 "ssids:" "${REPO_ROOT}/config.yaml" | grep "name:" | head -1 | cut -d'"' -f2 || echo "")
    fi
    
    if [[ -z "$wifi_ssid" ]]; then
        read -p "Enter WiFi SSID: " wifi_ssid
        read -sp "Enter WiFi password: " wifi_pass
        echo
    fi
    
    if [[ -n "$wifi_ssid" && -n "$wifi_pass" ]]; then
        ssh "${PI_USER}@${pi_host}" "sudo nmcli device wifi connect '${wifi_ssid}' password '${wifi_pass}'" || {
            warn "nmcli failed, trying wpa_supplicant method..."
            ssh "${PI_USER}@${pi_host}" "cat << EOF | sudo tee /etc/wpa_supplicant/wpa_supplicant.conf
country=US
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
network={
    ssid=\"${wifi_ssid}\"
    psk=\"${wifi_pass}\"
}
EOF
sudo systemctl restart wpa_supplicant"
        }
        log "WiFi configured ✓"
    fi
}

#===============================================================================
# Configure Static IP (via DHCP reservation recommendation)
#===============================================================================
configure_static_ip() {
    local pi_host="$1"
    local target_ip="$2"
    
    log "Configuring static IP: ${target_ip}"
    
    # Get Pi's MAC address for DHCP reservation
    local mac_address
    mac_address=$(ssh "${PI_USER}@${pi_host}" "cat /sys/class/net/eth0/address 2>/dev/null || cat /sys/class/net/wlan0/address")
    
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo "  DHCP Reservation Required"
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    echo "  To ensure stable networking, configure your router to reserve:"
    echo ""
    echo "    MAC Address: ${mac_address}"
    echo "    IP Address:  ${target_ip}"
    echo "    Hostname:    $(ssh "${PI_USER}@${pi_host}" 'hostname')"
    echo ""
    echo "  This is more reliable than static IP configuration on the Pi."
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
}

#===============================================================================
# Enable Always-On K3s (systemd)
#===============================================================================
enable_always_on() {
    local pi_host="$1"
    log "Enabling always-on K3s via systemd..."
    
    ssh "${PI_USER}@${pi_host}" << 'REMOTE_SCRIPT'
        # Enable K3s to start on boot
        if systemctl list-unit-files | grep -q k3s; then
            sudo systemctl enable k3s
            sudo systemctl start k3s || true
            echo "K3s enabled for auto-start on boot"
        else
            echo "K3s not yet installed - will be enabled after installation"
        fi
        
        # Configure kernel parameters for K8s
        sudo tee /etc/sysctl.d/k8s.conf << EOF
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
        sudo sysctl --system
        
        # Disable swap (required for K8s)
        sudo swapoff -a
        sudo sed -i '/ swap / s/^/#/' /etc/fstab
        
        # Enable cgroups (required for K3s)
        if ! grep -q "cgroup_memory=1" /boot/firmware/cmdline.txt; then
            sudo sed -i 's/$/ cgroup_memory=1 cgroup_enable=memory/' /boot/firmware/cmdline.txt
            echo "Cgroups enabled - REBOOT REQUIRED"
        fi
REMOTE_SCRIPT
    
    log "Always-on configuration complete ✓"
}

#===============================================================================
# Install K3s
#===============================================================================
install_k3s() {
    local pi_host="$1"
    local role="${2:-server}"  # server or agent
    local server_url="${3:-}"  # For agents: URL of server
    local token="${4:-}"       # For agents: Join token
    
    log "Installing K3s (${role}) on Pi..."
    log "This may take 2-5 minutes on first run..."
    
    if [[ "$role" == "server" ]]; then
        # K3s server with optimizations for Pi stability
        ssh "${PI_USER}@${pi_host}" << REMOTE_SCRIPT
            # Install K3s with settings optimized for Raspberry Pi
            curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - server \
                --write-kubeconfig-mode 644 \
                --disable traefik \
                --disable servicelb \
                --kubelet-arg="max-pods=50" \
                --kubelet-arg="kube-reserved=cpu=200m,memory=256Mi" \
                --kubelet-arg="system-reserved=cpu=200m,memory=256Mi" \
                --node-label "topology.kubernetes.io/zone=edge" \
                --node-label "hardware=raspberry-pi" \
                --node-label "workload-type=iot"
REMOTE_SCRIPT
    else
        if [[ -z "$server_url" || -z "$token" ]]; then
            error "Agent install requires --server-url and --token"
            return 1
        fi
        ssh "${PI_USER}@${pi_host}" << REMOTE_SCRIPT
            curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" K3S_URL="${server_url}" K3S_TOKEN="${token}" sh -s - agent \
                --kubelet-arg="max-pods=50" \
                --kubelet-arg="kube-reserved=cpu=200m,memory=256Mi" \
                --kubelet-arg="system-reserved=cpu=200m,memory=256Mi" \
                --node-label "topology.kubernetes.io/zone=edge" \
                --node-label "hardware=raspberry-pi"
REMOTE_SCRIPT
    fi
    
    # Enable auto-start
    ssh "${PI_USER}@${pi_host}" "sudo systemctl enable k3s || sudo systemctl enable k3s-agent"
    
    log "K3s ${role} installed and enabled ✓"
}

#===============================================================================
# Wait for K3s to be Ready (with polling)
#===============================================================================
wait_for_k3s_ready() {
    local pi_host="$1"
    local max_attempts="${2:-60}"  # Default 60 attempts = 5 minutes
    local interval="${3:-5}"       # Check every 5 seconds
    
    log "Waiting for K3s to be ready (max ${max_attempts} attempts, ${interval}s interval)..."
    
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        # Check if k3s.service is active
        if ssh -o ConnectTimeout=5 "${PI_USER}@${pi_host}" "sudo systemctl is-active k3s" &>/dev/null; then
            # Check if kubectl can reach the API server
            if ssh -o ConnectTimeout=5 "${PI_USER}@${pi_host}" "sudo k3s kubectl get nodes" &>/dev/null; then
                # Check if node is Ready
                local node_status
                node_status=$(ssh "${PI_USER}@${pi_host}" "sudo k3s kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}'" 2>/dev/null)
                if [[ "$node_status" == "True" ]]; then
                    log "K3s is ready! Node status: Ready ✓"
                    return 0
                fi
            fi
        fi
        
        # Show progress with resource usage
        if [[ $((attempt % 6)) -eq 0 ]]; then  # Every 30 seconds
            local cpu_usage
            cpu_usage=$(ssh -o ConnectTimeout=5 "${PI_USER}@${pi_host}" "top -bn1 | grep 'Cpu(s)' | awk '{print \$2}'" 2>/dev/null || echo "N/A")
            local mem_usage
            mem_usage=$(ssh -o ConnectTimeout=5 "${PI_USER}@${pi_host}" "free -m | awk '/^Mem:/{printf \"%.0f%%\", \$3/\$2*100}'" 2>/dev/null || echo "N/A")
            log "  Attempt ${attempt}/${max_attempts} - CPU: ${cpu_usage}%, Mem: ${mem_usage} - Still initializing..."
        else
            debug "  Attempt ${attempt}/${max_attempts} - K3s not ready yet..."
        fi
        
        sleep "$interval"
        attempt=$((attempt + 1))
    done
    
    error "K3s did not become ready within $((max_attempts * interval)) seconds"
    error "Check Pi logs with: ssh ${PI_USER}@${pi_host} 'sudo journalctl -u k3s -n 100'"
    return 1
}

#===============================================================================
# Fetch Kubeconfig from Pi (with retry)
#===============================================================================
fetch_kubeconfig() {
    local pi_host="$1"
    local target_ip="$2"
    local max_attempts="${3:-10}"
    
    log "Fetching kubeconfig from Pi..."
    
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        # Check if kubeconfig file exists
        if ssh "${PI_USER}@${pi_host}" "test -f /etc/rancher/k3s/k3s.yaml" &>/dev/null; then
            mkdir -p ~/.kube
            if scp "${PI_USER}@${pi_host}:/etc/rancher/k3s/k3s.yaml" ~/.kube/pi-config 2>/dev/null; then
                # Update the server address to Pi's IP
                if [[ "$(uname)" == "Darwin" ]]; then
                    sed -i '' "s/127.0.0.1/${target_ip}/g" ~/.kube/pi-config
                else
                    sed -i "s/127.0.0.1/${target_ip}/g" ~/.kube/pi-config
                fi
                log "Kubeconfig saved to ~/.kube/pi-config ✓"
                log "To use: export KUBECONFIG=~/.kube/pi-config"
                return 0
            fi
        fi
        
        warn "Kubeconfig not yet available (attempt ${attempt}/${max_attempts}), waiting..."
        sleep 5
        attempt=$((attempt + 1))
    done
    
    error "Failed to fetch kubeconfig after ${max_attempts} attempts"
    return 1
}

#===============================================================================
# Run Ansible Playbook (with pre-checks and retries)
#===============================================================================
run_ansible() {
    local pi_host="$1"
    local max_retries="${2:-3}"
    
    log "Running Ansible playbook for full configuration..."
    
    # Update inventory with Pi IP (use the ansible subdirectory inventory)
    local inventory="${REPO_ROOT}/pi-setup/ansible/inventory.ini"
    local playbook="${REPO_ROOT}/pi-setup/ansible/playbook.yml"
    local ansible_cfg="${REPO_ROOT}/pi-setup/ansible/ansible.cfg"
    
    if [[ ! -f "$playbook" ]]; then
        warn "Ansible playbook not found at $playbook"
        warn "Skipping Ansible configuration"
        return 0
    fi
    
    # Pre-flight: Ensure Pi is reachable before Ansible
    log "Pre-flight: Verifying Pi connectivity before Ansible..."
    local preflight_attempts=0
    local preflight_max=5
    while [[ $preflight_attempts -lt $preflight_max ]]; do
        if ssh -o ConnectTimeout=10 -o BatchMode=yes "${PI_USER}@${pi_host}" "echo 'Pre-flight OK'" &>/dev/null; then
            log "Pre-flight connectivity check passed ✓"
            break
        fi
        preflight_attempts=$((preflight_attempts + 1))
        if [[ $preflight_attempts -lt $preflight_max ]]; then
            warn "Pre-flight attempt ${preflight_attempts}/${preflight_max} failed, waiting 10s..."
            sleep 10
        fi
    done
    
    if [[ $preflight_attempts -ge $preflight_max ]]; then
        error "Pi not reachable before Ansible. Cannot proceed."
        error "Check Pi network connectivity and try again."
        return 1
    fi
    
    # Pre-flight: Disable WiFi power save on Pi for stability during Ansible
    log "Disabling WiFi power save for Ansible stability..."
    ssh -o ConnectTimeout=10 "${PI_USER}@${pi_host}" "sudo iw dev wlan0 set power_save off 2>/dev/null || true" || true
    
    # Pre-flight: Check Pi resources (warn if low)
    log "Checking Pi resource availability..."
    local mem_free
    mem_free=$(ssh -o ConnectTimeout=10 "${PI_USER}@${pi_host}" "free -m | awk '/^Mem:/{print \$7}'" 2>/dev/null || echo "0")
    if [[ -n "$mem_free" ]] && [[ "$mem_free" -lt 500 ]]; then
        warn "Low memory on Pi: ${mem_free}MB available. Ansible may be slow or fail."
    else
        debug "Pi memory available: ${mem_free}MB ✓"
    fi
    
    # Update inventory with current Pi IP
    log "Updating inventory with Pi IP: ${pi_host}"
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/ansible_host=.*/ansible_host=${pi_host}/" "$inventory"
    else
        sed -i "s/ansible_host=.*/ansible_host=${pi_host}/" "$inventory"
    fi
    
    # Run Ansible with retries
    local attempt=1
    while [[ $attempt -le $max_retries ]]; do
        log "Ansible attempt ${attempt}/${max_retries}..."
        
        # Set environment for ansible.cfg
        export ANSIBLE_CONFIG="$ansible_cfg"
        
        # Run with verbose output on retry
        local verbosity=""
        if [[ $attempt -gt 1 ]]; then
            verbosity="-vv"
            warn "Retrying with increased verbosity..."
        fi
        
        if ansible-playbook -i "$inventory" "$playbook" \
            --extra-vars "pi_ip=${pi_host}" \
            --extra-vars "k3s_version=${K3S_VERSION}" \
            --extra-vars "ansible_host=${pi_host}" \
            $verbosity; then
            log "Ansible playbook completed successfully ✓"
            return 0
        fi
        
        local exit_code=$?
        warn "Ansible attempt ${attempt} failed with exit code: ${exit_code}"
        
        if [[ $attempt -lt $max_retries ]]; then
            # Check if Pi is still reachable
            log "Checking if Pi is still reachable..."
            local recovery_attempts=0
            local recovery_max=12  # 12 * 10s = 2 minutes
            while [[ $recovery_attempts -lt $recovery_max ]]; do
                if ssh -o ConnectTimeout=5 -o BatchMode=yes "${PI_USER}@${pi_host}" "echo 'Recovery OK'" &>/dev/null; then
                    log "Pi recovered and is reachable ✓"
                    break
                fi
                recovery_attempts=$((recovery_attempts + 1))
                if [[ $recovery_attempts -lt $recovery_max ]]; then
                    warn "  Waiting for Pi to recover... (${recovery_attempts}/${recovery_max})"
                    sleep 10
                fi
            done
            
            if [[ $recovery_attempts -ge $recovery_max ]]; then
                error "Pi did not recover within 2 minutes. It may have crashed or rebooted."
                error "Please check Pi manually (power cycle if needed) and retry."
                return 1
            fi
            
            # Re-disable WiFi power save after recovery
            ssh -o ConnectTimeout=10 "${PI_USER}@${pi_host}" "sudo iw dev wlan0 set power_save off 2>/dev/null || true" || true
            
            warn "Waiting 30s before retry..."
            sleep 30
        fi
        
        attempt=$((attempt + 1))
    done
    
    error "Ansible playbook failed after ${max_retries} attempts"
    error "Check Pi logs: ssh ${PI_USER}@${pi_host} 'sudo journalctl -n 200'"
    return 1
}

#===============================================================================
# Show New Pi Instructions
#===============================================================================
show_new_pi_instructions() {
    cat << 'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                      New Raspberry Pi 5 Setup Instructions                     ║
╚═══════════════════════════════════════════════════════════════════════════════╝

STEP 1: FLASH THE SD CARD
─────────────────────────
1. Download Raspberry Pi Imager: https://www.raspberrypi.com/software/
2. Insert your SD card (32GB+ recommended)
3. Open Imager and select:
   - Device: Raspberry Pi 5
   - OS: Raspberry Pi OS Lite (64-bit) - NO desktop
   - Storage: Your SD card

4. Click the GEAR ICON (⚙️) to configure:
   ┌────────────────────────────────────┐
   │ Set hostname:     pi5-master-1    │
   │ Enable SSH:       ✓ Yes           │
   │ Username:         admin           │
   │ Password:         (your choice)   │
   │ Configure WiFi:   (optional)      │
   │ Locale:           Your timezone   │
   └────────────────────────────────────┘

5. Click SAVE, then WRITE

STEP 2: CLOUD-INIT (OPTIONAL - Advanced)
────────────────────────────────────────
For fully automated setup, copy cloud-init files to the boot partition:
   cp pi-setup/cloud-init/user-data.yaml /Volumes/bootfs/user-data
   cp pi-setup/cloud-init/meta-data.yaml /Volumes/bootfs/meta-data
   cp pi-setup/cloud-init/network-config.yaml /Volumes/bootfs/network-config

STEP 3: BOOT THE PI
───────────────────
1. Insert SD card into Pi
2. Connect ethernet (recommended) or ensure WiFi is configured
3. Connect power
4. Wait 2-3 minutes for first boot

STEP 4: FIND YOUR PI
────────────────────
Option A (mDNS):
   ping pi5-master-1.local

Option B (Network scan):
   # Find devices on your network
   arp -a | grep -i "d8:3a\|dc:a6\|e4:5f"  # Raspberry Pi MAC prefixes

Option C (Router):
   Check your router's DHCP client list

STEP 5: RUN THIS SCRIPT AGAIN
─────────────────────────────
Once you can ping the Pi, run:
   ./pi-prep.sh <PI_IP> --join-cluster

═══════════════════════════════════════════════════════════════════════════════
EOF
    
    read -p "Press ENTER when Pi is ready, or Ctrl+C to exit..."
}

#===============================================================================
# Main
#===============================================================================
main() {
    local pi_host=""
    local new_pi=false
    local join_cluster=false
    local wifi_only=false
    local dry_run=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --new-pi)
                new_pi=true
                shift
                ;;
            --join-cluster)
                join_cluster=true
                shift
                ;;
            --wifi-only)
                wifi_only=true
                shift
                ;;
            --dry-run)
                dry_run=true
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
            -*)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                pi_host="$1"
                shift
                ;;
        esac
    done
    
    # Validate arguments
    if [[ -z "$pi_host" && "$new_pi" != "true" ]]; then
        error "PI_IP_OR_HOSTNAME is required"
        show_help
        exit 1
    fi
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
    echo "║                     Pi Preparation for kube-world                              ║"
    echo "║                     $(date '+%Y-%m-%d %H:%M:%S')                                        ║"
    echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Check prerequisites
    check_prereqs
    
    # New Pi flow
    if [[ "$new_pi" == "true" ]]; then
        show_new_pi_instructions
        if [[ -z "$pi_host" ]]; then
            read -p "Enter Pi IP address or hostname: " pi_host
        fi
    fi
    
    # Dry run mode
    if [[ "$dry_run" == "true" ]]; then
        log "DRY RUN MODE - showing what would be done:"
        echo "  1. Test SSH to ${pi_host}"
        [[ "$wifi_only" == "true" ]] && echo "  2. Configure WiFi"
        [[ "$join_cluster" == "true" ]] && echo "  2. Enable always-on config"
        [[ "$join_cluster" == "true" ]] && echo "  3. Install K3s"
        [[ "$join_cluster" == "true" ]] && echo "  4. Fetch kubeconfig"
        [[ "$join_cluster" == "true" ]] && echo "  5. Run Ansible playbook"
        exit 0
    fi
    
    # Test connectivity
    test_ssh "$pi_host" || exit 1
    
    # WiFi only
    if [[ "$wifi_only" == "true" ]]; then
        configure_wifi "$pi_host"
        log "WiFi configuration complete!"
        exit 0
    fi
    
    # Full cluster join
    if [[ "$join_cluster" == "true" ]]; then
        log "Starting full cluster join process..."
        
        # Get target IP for static config
        local target_ip
        target_ip=$(ssh "${PI_USER}@${pi_host}" "hostname -I | awk '{print \$1}'")
        
        # Configure basics
        enable_always_on "$pi_host"
        
        # Check if reboot needed
        if ssh "${PI_USER}@${pi_host}" "grep -q 'cgroup_memory=1' /boot/firmware/cmdline.txt" 2>/dev/null; then
            if ! ssh "${PI_USER}@${pi_host}" "cat /proc/cmdline | grep -q cgroup_memory=1" 2>/dev/null; then
                warn "Cgroups were just enabled. Rebooting Pi..."
                # Use -t for TTY allocation (required for sudo on some systems)
                # Use nohup to ensure reboot completes even if SSH disconnects
                ssh -t "${PI_USER}@${pi_host}" "sudo nohup sh -c 'sleep 2 && reboot' &>/dev/null &" || true
                log "Waiting for Pi to reboot (90s timeout)..."
                sleep 15  # Wait for Pi to actually start rebooting
                
                # Poll for SSH to come back (up to 90 seconds)
                local reboot_attempts=0
                local max_reboot_wait=18  # 18 * 5s = 90s
                while [[ $reboot_attempts -lt $max_reboot_wait ]]; do
                    sleep 5
                    reboot_attempts=$((reboot_attempts + 1))
                    if ssh -o ConnectTimeout=3 -o BatchMode=yes "${PI_USER}@${pi_host}" "echo 'SSH OK'" &>/dev/null; then
                        log "Pi is back online after reboot ✓"
                        break
                    fi
                    debug "  Waiting for reboot... (${reboot_attempts}/${max_reboot_wait})"
                done
                
                if [[ $reboot_attempts -ge $max_reboot_wait ]]; then
                    error "Pi didn't come back after reboot within 90 seconds"
                    error "Please check Pi manually and try again"
                    exit 1
                fi
            fi
        fi
        
        # Install K3s
        install_k3s "$pi_host" "server"
        
        # Disable WiFi power save immediately after K3s install to prevent disconnects
        log "Disabling WiFi power save for stability..."
        ssh "${PI_USER}@${pi_host}" "sudo iw dev wlan0 set power_save off 2>/dev/null || true" || true
        
        # Wait for K3s to be ready with proper polling
        if ! wait_for_k3s_ready "$pi_host" 60 5; then
            error "K3s installation may have issues. Please check Pi manually."
            error "Try: ssh ${PI_USER}@${pi_host} 'sudo journalctl -u k3s -f'"
            exit 1
        fi
        
        # Fetch kubeconfig (with retry)
        if ! fetch_kubeconfig "$pi_host" "$target_ip" 10; then
            error "Failed to fetch kubeconfig. K3s may still be initializing."
            exit 1
        fi
        
        # Final stability check - verify WiFi is still connected
        log "Verifying network stability..."
        if ! ssh -o ConnectTimeout=5 "${PI_USER}@${pi_host}" "ping -c 2 8.8.8.8" &>/dev/null; then
            warn "Network connectivity may be unstable. Consider using Ethernet for Pi."
        else
            log "Network connectivity verified ✓"
        fi
        
        # Show static IP recommendation
        configure_static_ip "$pi_host" "$target_ip"
        
        # Run Ansible for additional config
        run_ansible "$pi_host"
        
        echo ""
        echo "╔═══════════════════════════════════════════════════════════════════════════════╗"
        echo "║                     Pi Preparation Complete! 🎉                                ║"
        echo "╚═══════════════════════════════════════════════════════════════════════════════╝"
        echo ""
        echo "  Pi IP:        ${target_ip}"
        echo "  Kubeconfig:   ~/.kube/pi-config"
        echo ""
        echo "  To access the Pi cluster:"
        echo "    export KUBECONFIG=~/.kube/pi-config"
        echo "    kubectl get nodes"
        echo ""
        echo "  To register with Rancher (from Mac cluster):"
        echo "    1. Access Rancher UI"
        echo "    2. Go to Cluster Management > Import Existing"
        echo "    3. Follow the instructions to import the Pi cluster"
        echo ""
    fi
}

main "$@"
