#!/usr/bin/env bash
#===============================================================================
# WiFi Stability Configuration for Raspberry Pi
#
# Addresses common WiFi issues on Raspberry Pi:
#   - Power save causing disconnects
#   - Country code not set (affects 5GHz)
#   - DHCP client timeout too aggressive
#   - Network interface not bringing up after reboot
#
# Run on Pi to apply all stability fixes
#===============================================================================
set -euo pipefail

log() { echo -e "\033[0;32m[WIFI]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WIFI]\033[0m $*"; }
error() { echo -e "\033[0;31m[WIFI]\033[0m $*" >&2; }

#===============================================================================
# Disable WiFi Power Save
#===============================================================================
disable_power_save() {
    log "Disabling WiFi power save..."

    # Immediate disable
    iw dev wlan0 set power_save off 2>/dev/null || true

    # Create persistent configuration
    local conf_file="/etc/NetworkManager/conf.d/wifi-powersave-off.conf"
    if command -v nmcli &>/dev/null; then
        mkdir -p /etc/NetworkManager/conf.d
        cat > "$conf_file" << 'EOF'
[connection]
wifi.powersave = 2
EOF
        log "Created NetworkManager power save config"
    fi

    # Alternative: udev rule for direct iw control
    local udev_rule="/etc/udev/rules.d/70-wifi-powersave.rules"
    cat > "$udev_rule" << 'EOF'
# Disable WiFi power save on wlan0
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan0", RUN+="/usr/sbin/iw dev wlan0 set power_save off"
EOF
    log "Created udev rule for power save"

    # Systemd service as backup
    local service_file="/etc/systemd/system/wifi-powersave-off.service"
    cat > "$service_file" << 'EOF'
[Unit]
Description=Disable WiFi Power Save
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/iw dev wlan0 set power_save off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable wifi-powersave-off.service
    log "Created and enabled wifi-powersave-off service"
}

#===============================================================================
# Set WiFi Country Code
#===============================================================================
set_country_code() {
    local country="${1:-US}"

    log "Setting WiFi country code to: ${country}"

    # Set via iw
    iw reg set "$country" 2>/dev/null || true

    # Persist in wpa_supplicant
    if [[ -f /etc/wpa_supplicant/wpa_supplicant.conf ]]; then
        if ! grep -q "country=" /etc/wpa_supplicant/wpa_supplicant.conf; then
            sed -i "1i country=${country}" /etc/wpa_supplicant/wpa_supplicant.conf
            log "Added country code to wpa_supplicant.conf"
        fi
    fi

    # Persist in raspi-config style
    if command -v raspi-config &>/dev/null; then
        raspi-config nonint do_wifi_country "$country" 2>/dev/null || true
    fi
}

#===============================================================================
# Configure DHCP Client for Better Reliability
#===============================================================================
configure_dhcp() {
    log "Configuring DHCP client for reliability..."

    local dhcpcd_conf="/etc/dhcpcd.conf"
    if [[ -f "$dhcpcd_conf" ]]; then
        # Backup
        cp "$dhcpcd_conf" "${dhcpcd_conf}.bak"

        # Add reliability settings if not present
        if ! grep -q "timeout 60" "$dhcpcd_conf"; then
            cat >> "$dhcpcd_conf" << 'EOF'

# Reliability improvements for K3s
# Longer timeout for DHCP lease
timeout 60

# Retry faster
retry 15

# Renew before lease expires
reboot 10

# Don't give up on DHCP
persistent

# Allow multiple addresses
allowinterfaces eth* wlan*
EOF
            log "Added DHCP reliability settings"
        fi
    fi
}

#===============================================================================
# Configure Network Interface Watchdog
#===============================================================================
configure_watchdog() {
    log "Configuring network watchdog..."

    # Create watchdog script
    local watchdog_script="/usr/local/bin/wifi-watchdog.sh"
    cat > "$watchdog_script" << 'EOF'
#!/bin/bash
# WiFi Watchdog - restarts network if connection lost

GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
INTERFACE="wlan0"

if [[ -n "$GATEWAY" ]]; then
    if ! ping -c 3 -W 5 -I $INTERFACE $GATEWAY &>/dev/null; then
        logger -t wifi-watchdog "Network unreachable, restarting interface"
        ip link set $INTERFACE down
        sleep 2
        ip link set $INTERFACE up

        # If using NetworkManager
        if command -v nmcli &>/dev/null; then
            nmcli device connect $INTERFACE 2>/dev/null || true
        fi

        # If using dhcpcd
        if command -v dhcpcd &>/dev/null; then
            dhcpcd -n $INTERFACE 2>/dev/null || true
        fi
    fi
fi
EOF
    chmod +x "$watchdog_script"

    # Create systemd timer
    local timer_file="/etc/systemd/system/wifi-watchdog.timer"
    cat > "$timer_file" << 'EOF'
[Unit]
Description=WiFi Watchdog Timer

[Timer]
OnBootSec=60
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
EOF

    local service_file="/etc/systemd/system/wifi-watchdog.service"
    cat > "$service_file" << 'EOF'
[Unit]
Description=WiFi Watchdog
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wifi-watchdog.sh
EOF

    systemctl daemon-reload
    systemctl enable wifi-watchdog.timer
    systemctl start wifi-watchdog.timer
    log "Watchdog timer configured and started"
}

#===============================================================================
# Optimize WiFi Driver Parameters
#===============================================================================
optimize_driver() {
    log "Optimizing WiFi driver parameters..."

    # For the common brcmfmac driver (Pi built-in WiFi)
    local driver_conf="/etc/modprobe.d/brcmfmac.conf"
    cat > "$driver_conf" << 'EOF'
# Improve reliability for brcmfmac (Broadcom WiFi)
options brcmfmac roamoff=1
EOF
    log "Created brcmfmac driver config"
}

#===============================================================================
# Main
#===============================================================================
main() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (sudo)"
        exit 1
    fi

    log "Applying WiFi stability configurations..."

    disable_power_save
    set_country_code "${WIFI_COUNTRY:-US}"
    configure_dhcp
    configure_watchdog
    optimize_driver

    echo ""
    log "=============================================="
    log "  WiFi Stability Configuration Complete!"
    log "=============================================="
    log ""
    log "  Changes applied:"
    log "    - Power save disabled"
    log "    - Country code set"
    log "    - DHCP client optimized"
    log "    - Network watchdog enabled"
    log "    - Driver parameters optimized"
    log ""
    log "  Recommend rebooting for all changes to take effect:"
    log "    sudo reboot"
    log ""
}

main "$@"
