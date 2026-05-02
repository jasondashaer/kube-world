#!/usr/bin/env bash
# Pironman 5 case integration installer.
#
# Idempotent. Designed to be invoked from bootstrap.sh per-Pi OR
# directly via SSH:
#
#   curl -fsSL https://raw.githubusercontent.com/jasondashaer/kube-world/main/scripts/install-pironman.sh | sudo bash
#   curl -fsSL ... | sudo bash -s -- --with-rgb-monitor
#
# What it does:
#   1. Installs i2c-tools (for OLED diagnostic).
#   2. Clones + installs SunFounder pironman5 + sf_rpi_status into
#      /opt/pironman5/venv. Skips if already installed.
#   3. Patches /boot/firmware/config.txt to enable I2C + load the
#      sunfounder-pironman5 dtoverlay (idempotent — checks first).
#   4. Patches pm_auto/oled.py so the OLED top bar rotates LAN IP →
#      hostname → Tailscale IP (instead of cycling all interfaces
#      including k8s/flannel internals).
#   5. Sets oled_sleep_timeout=0 so the display stays on permanently.
#   6. Optionally installs a metric-driven RGB monitor service that
#      replaces pironman5's static RGB animation with one that maps
#      live CPU / RAM / temp / K8s health to the case LEDs.
#
# Reboot is required after first install to pick up config.txt
# changes (I2C + dtoverlay). Use --skip-reboot to skip; reboot
# manually later.

set -euo pipefail

WITH_RGB_MONITOR=0
SKIP_REBOOT=0
REPO_RAW="${REPO_RAW:-https://raw.githubusercontent.com/jasondashaer/kube-world/main}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --with-rgb-monitor) WITH_RGB_MONITOR=1; shift ;;
        --skip-reboot) SKIP_REBOOT=1; shift ;;
        --help|-h) sed -n '2,/^set -euo pipefail/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: run as root (sudo)" >&2
    exit 1
fi

GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
log() { printf '%s[pironman]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YELLOW" "$RESET" "$*"; }

# ─────────────────────────────────────────────────────────────────
# Dependencies
# ─────────────────────────────────────────────────────────────────

log "Installing apt deps..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq i2c-tools git python3 python3-pip

# ─────────────────────────────────────────────────────────────────
# Clone + run pironman5 installer
# ─────────────────────────────────────────────────────────────────

if [[ -d /opt/pironman5/venv ]] && systemctl is-enabled pironman5 >/dev/null 2>&1; then
    log "pironman5 already installed at /opt/pironman5"
else
    log "Installing pironman5..."
    cd /tmp
    rm -rf pironman5
    git clone --depth 1 https://github.com/sunfounder/pironman5.git
    cd pironman5
    python3 install.py --skip-reboot --disable-dashboard --plain-text
    cd /tmp
    rm -rf sf_rpi_status
    git clone --depth 1 https://github.com/sunfounder/sf_rpi_status.git
    cd sf_rpi_status
    /opt/pironman5/venv/bin/pip install . --no-build-isolation
    log "pironman5 installed"
fi

# ─────────────────────────────────────────────────────────────────
# Patch config.txt for I2C + dtoverlay
# ─────────────────────────────────────────────────────────────────

CONFIG_TXT=/boot/firmware/config.txt
if ! grep -q "sunfounder-pironman5" "$CONFIG_TXT"; then
    log "Patching $CONFIG_TXT for I2C + dtoverlay..."
    cat >> "$CONFIG_TXT" <<EOF

# Pironman 5 case — added by kube-world
dtparam=i2c_arm=on
dtoverlay=sunfounder-pironman5
EOF
    REBOOT_REQUIRED=1
else
    log "$CONFIG_TXT already has Pironman 5 entries"
    REBOOT_REQUIRED=${REBOOT_REQUIRED:-0}
fi

# ─────────────────────────────────────────────────────────────────
# Patch oled.py — rotate LAN IP / hostname / Tailscale IP
# ─────────────────────────────────────────────────────────────────

OLED_PY=/opt/pironman5/venv/lib/python3.13/site-packages/pm_auto/oled.py
if [[ -f "$OLED_PY" ]] && ! grep -q "kube-world IP rotation" "$OLED_PY"; then
    log "Patching oled.py top-bar rotation..."
    python3 <<'PY'
import os
p = '/opt/pironman5/venv/lib/python3.13/site-packages/pm_auto/oled.py'
s = open(p).read()
old = '''            if self.ip_interface == 'all':
                data['ips'] = list(ips.values())'''
new = '''            if self.ip_interface == 'all':
                # kube-world IP rotation: filter k8s/internal interfaces
                # and rotate LAN IP → hostname → Tailscale IP only.
                import socket
                excluded = ('flannel', 'cni', 'docker', 'veth', 'lo')
                filtered = {k:v for k,v in ips.items() if not any(k.startswith(pre) for pre in excluded)}
                items = []
                if 'eth0' in filtered: items.append(filtered['eth0'])
                elif 'wlan0' in filtered: items.append(filtered['wlan0'])
                items.append(socket.gethostname())
                if 'tailscale0' in filtered: items.append(filtered['tailscale0'])
                data['ips'] = items if items else list(ips.values())'''
if old in s:
    open(p, 'w').write(s.replace(old, new))
    print('patched')
else:
    print('pattern not found — pironman5 may have changed schema')
PY
fi

# ─────────────────────────────────────────────────────────────────
# Patch config.json — disable OLED sleep
# ─────────────────────────────────────────────────────────────────

CONFIG_JSON=/opt/pironman5/venv/lib/python3.13/site-packages/pironman5/config.json
if [[ -f "$CONFIG_JSON" ]]; then
    log "Setting oled_sleep_timeout=0 in pironman5 config..."
    python3 -c "
import json
p = '$CONFIG_JSON'
d = json.load(open(p))
changed = False
if d.get('system', {}).get('oled_sleep_timeout') != 0:
    d['system']['oled_sleep_timeout'] = 0; changed = True
if d.get('system', {}).get('oled_enable') is not True:
    d['system']['oled_enable'] = True; changed = True
if changed:
    json.dump(d, open(p, 'w'), indent=4)
    print('updated')
else:
    print('already correct')
"
fi

# ─────────────────────────────────────────────────────────────────
# Optional: metric-driven RGB monitor
# ─────────────────────────────────────────────────────────────────

if [[ $WITH_RGB_MONITOR -eq 1 ]]; then
    log "Installing metric-driven RGB monitor..."

    # Disable pironman5's RGB so our monitor owns the LEDs
    python3 -c "
import json
p = '$CONFIG_JSON'
d = json.load(open(p))
if d.get('system', {}).get('rgb_enable') is not False:
    d['system']['rgb_enable'] = False
    json.dump(d, open(p, 'w'), indent=4)
    print('disabled pironman5 rgb')
"

    # Patch pm_auto/ws2812.py: when rgb_enable=False, skip the
    # clear()+show() write that races with our monitor. Default
    # behavior blanks the LEDs every 1s, fighting any external SPI
    # writes — visible as flicker / brightness pulse.
    WS2812_PY=/opt/pironman5/venv/lib/python3.13/site-packages/pm_auto/ws2812.py
    if [[ -f "$WS2812_PY" ]] && ! grep -q "kube-world rgb-monitor patch" "$WS2812_PY"; then
        log "Patching ws2812.py to release SPI when rgb_enable=False..."
        python3 <<'PY'
p = '/opt/pironman5/venv/lib/python3.13/site-packages/pm_auto/ws2812.py'
s = open(p).read()
old = """        while self.running:
            if not self.enable:
                self.clear()
                self.strip.show()
                time.sleep(1)
                continue"""
new = """        while self.running:
            if not self.enable:
                # kube-world rgb-monitor patch: when rgb_enable=False,
                # do NOT write to LEDs. Default clear()+show() blanks
                # the chain every 1s, racing with external monitors.
                time.sleep(1)
                continue"""
if old in s:
    open(p, 'w').write(s.replace(old, new))
    print('patched')
else:
    print('pattern not found')
PY
    fi

    # Install monitor script
    INSTALL_DIR=/opt/pironman-rgb-monitor
    mkdir -p "$INSTALL_DIR"
    curl -fsSL "$REPO_RAW/apps/pironman-rgb-monitor/rgb_monitor.py" -o "$INSTALL_DIR/rgb_monitor.py"
    chmod +x "$INSTALL_DIR/rgb_monitor.py"

    # systemd unit
    curl -fsSL "$REPO_RAW/apps/pironman-rgb-monitor/rgb-monitor.service" \
        -o /etc/systemd/system/rgb-monitor.service
    systemctl daemon-reload

    # Restart pironman5 to pick up rgb_enable=false, then start our monitor
    systemctl restart pironman5
    systemctl enable --now rgb-monitor

    log "RGB monitor active. Logs: journalctl -u rgb-monitor -f"
else
    # If not installing rgb monitor, ensure pironman5 RGB stays enabled
    python3 -c "
import json
p = '$CONFIG_JSON'
d = json.load(open(p))
if d.get('system', {}).get('rgb_enable') is False:
    d['system']['rgb_enable'] = True
    json.dump(d, open(p, 'w'), indent=4)
    print('re-enabled pironman5 rgb')
"
    systemctl restart pironman5 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────────────
# Reboot if needed
# ─────────────────────────────────────────────────────────────────

if [[ ${REBOOT_REQUIRED:-0} -eq 1 ]]; then
    if [[ $SKIP_REBOOT -eq 1 ]]; then
        warn "config.txt was modified — reboot required to take effect."
        warn "Run: sudo reboot"
    else
        log "Rebooting in 5s to apply config.txt changes..."
        sleep 5
        reboot
    fi
fi

log "Done."
