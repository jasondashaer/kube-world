# Raspberry Pi Setup Guide

Complete guide for provisioning Raspberry Pi nodes for kube-world.

## Hardware Requirements

### Minimum (Testing)
- Raspberry Pi 4 (4GB RAM)
- 32GB microSD card (Class 10)
- USB-C power supply (5V/3A)
- Ethernet cable (recommended) or WiFi

### Recommended (Production)
- **Raspberry Pi 5 (8GB or 16GB RAM)**
- **NVMe SSD** via M.2 HAT (e.g., Pimoroni NVMe Base, Argon ONE M.2)
- Official Pi 5 power supply (27W)
- Ethernet connection
- Active cooling (heatsink + fan)

### For Home Assistant IoT
- Z-Wave USB controller (e.g., Zooz ZST39 800LR)
- Zigbee USB controller (e.g., Sonoff Zigbee 3.0)
- Thread/Matter border router (optional)

## Provisioning Methods

### Method 1: Cloud-Init (Zero-Touch) - Recommended

1. **Download Ubuntu Server 24.04 LTS (arm64)**
   - Use Raspberry Pi Imager or download directly

2. **Flash to SD card/NVMe**
   ```bash
   # Using Raspberry Pi Imager CLI
   rpi-imager --cli ubuntu-24.04-preinstalled-server-arm64+raspi.img.xz /dev/diskX
   ```

3. **Generate cloud-init files with the builder script**
   ```bash
   cd pi-setup/cloud-init
   
   # Worker node with WiFi
   ./build-cloud-init.sh \
       --hostname pi-worker-1 \
       --role worker \
       --wifi-ssid "YourNetwork" \
       --wifi-pass "YourPassword" \
       --user-pass "AdminPassword123" \
       --copy-to /Volumes/system-boot
   
   # Master node with static IP (ethernet)
   ./build-cloud-init.sh \
       --hostname pi-master-1 \
       --role master \
       --ip 192.168.1.100/24 \
       --gateway 192.168.1.1 \
       --user-pass "AdminPassword123" \
       --copy-to /Volumes/system-boot
   ```
   
   The script automatically:
   - Generates WPA PSK hash for WiFi passwords
   - Creates SHA-512 hash for user passwords
   - Pulls your SSH public key from `~/.ssh/`
   - Validates all YAML output

4. **Boot the Pi**
   - Insert SD card/NVMe
   - Connect ethernet (or WiFi if configured)
   - Power on
   - Wait ~5 minutes for cloud-init

5. **Verify connection**
   ```bash
   # SSH with your configured username
   ssh admin@pi-worker-1.local
   ```

6. **Run Ansible from management machine**
   ```bash
   # Update inventory with Pi's IP
   vim pi-setup/inventory.ini
   
   # Run playbook
   ansible-playbook -i pi-setup/inventory.ini pi-setup/ansible/playbook.yml
   ```

### Method 2: Manual Setup

1. **Flash Ubuntu Server**
   ```bash
   # Using Raspberry Pi Imager with settings:
   # - Enable SSH
   # - Set username/password
   # - Configure WiFi (if needed)
   ```

2. **First boot configuration**
   ```bash
   ssh admin@<pi-ip>
   
   # Update system
   sudo apt update && sudo apt upgrade -y
   
   # Install prerequisites
   sudo apt install -y curl git
   
   # Clone repo
   git clone https://github.com/jasondashaer/kube-world.git
   cd kube-world
   
   # Run setup script
   sudo ./pi-setup/scripts/bootstrap.sh
   ```

3. **Install K3s**
   ```bash
   # Master node
   curl -sfL https://get.k3s.io | sh -s - server \
     --cluster-init \
     --disable traefik \
     --disable servicelb \
     --write-kubeconfig-mode 644
   
   # Get token for workers
   sudo cat /var/lib/rancher/k3s/server/node-token
   ```

### Method 3: k3sup (Remote Installation)

Install K3s remotely from your Mac:

```bash
# Install k3sup
brew install k3sup

# Install K3s on Pi (master)
k3sup install \
  --ip 192.168.1.100 \
  --user admin \
  --ssh-key ~/.ssh/id_ed25519 \
  --k3s-version v1.29.0+k3s1 \
  --k3s-extra-args '--disable traefik --disable servicelb' \
  --local-path ~/.kube/pi-config \
  --context pi-cluster

# Join worker node
k3sup join \
  --ip 192.168.1.101 \
  --server-ip 192.168.1.100 \
  --user admin \
  --ssh-key ~/.ssh/id_ed25519 \
  --k3s-version v1.29.0+k3s1
```

## NVMe Setup

### Pimoroni NVMe Base

1. **Physical installation**
   - Attach M.2 SSD to NVMe Base
   - Connect to Pi 5 via FPC cable
   - Ensure proper seating

2. **Configure boot order**
   ```bash
   # Edit EEPROM config
   sudo rpi-eeprom-config --edit
   
   # Set boot order (NVMe first, then SD)
   BOOT_ORDER=0xf416
   ```

3. **Clone SD to NVMe**
   ```bash
   # Install rpi-clone
   git clone https://github.com/billw2/rpi-clone.git
   cd rpi-clone
   sudo cp rpi-clone rpi-clone-setup /usr/local/sbin/
   
   # Clone to NVMe
   sudo rpi-clone nvme0n1
   ```

4. **Verify boot from NVMe**
   ```bash
   # Remove SD card and reboot
   # Check boot device
   lsblk
   findmnt /
   ```

## Network Configuration

### Static IP (Recommended for K8s)

Edit `/etc/netplan/50-cloud-init.yaml`:
```yaml
network:
  version: 2
  ethernets:
    eth0:
      dhcp4: false
      addresses:
        - 192.168.1.100/24
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
```

Apply:
```bash
sudo netplan apply
```

### DHCP Reservation (Alternative)

Configure in your router to always assign the same IP to the Pi's MAC address.

## USB Device Setup

### Z-Wave Controller

```bash
# Identify device
ls -la /dev/ttyUSB* /dev/ttyACM*

# Check device details
udevadm info -a -n /dev/ttyUSB0 | grep -E 'ATTRS{idVendor}|ATTRS{idProduct}'

# Create udev rule for consistent naming
sudo tee /etc/udev/rules.d/99-zwave.rules << 'EOF'
SUBSYSTEM=="tty", ATTRS{idVendor}=="0658", ATTRS{idProduct}=="0200", SYMLINK+="zwave", MODE="0666"
EOF

sudo udevadm control --reload-rules
sudo udevadm trigger
```

### Zigbee Controller

```bash
# Similar process for Zigbee
sudo tee /etc/udev/rules.d/99-zigbee.rules << 'EOF'
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", SYMLINK+="zigbee", MODE="0666"
EOF

sudo udevadm control --reload-rules
```

## Performance Tuning

### CPU Governor
```bash
# Set to performance mode
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Make persistent
sudo apt install cpufrequtils
echo 'GOVERNOR="performance"' | sudo tee /etc/default/cpufrequtils
```

### Memory Settings
```bash
# Increase kernel memory for containers
sudo tee /etc/sysctl.d/99-kubernetes.conf << 'EOF'
vm.swappiness = 0
vm.overcommit_memory = 1
net.core.somaxconn = 65535
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system
```

## Monitoring

### Temperature
```bash
# Check CPU temperature
vcgencmd measure_temp

# Continuous monitoring
watch -n 1 vcgencmd measure_temp
```

### Resource Usage
```bash
# Install htop
sudo apt install htop iotop

# Monitor
htop
```

## Troubleshooting

### K3s won't start
```bash
# Check status
sudo systemctl status k3s

# View logs
sudo journalctl -u k3s -f

# Common fix: ensure cgroups
cat /proc/cmdline | grep cgroup
# Should show: cgroup_memory=1 cgroup_enable=memory
```

### USB device not detected
```bash
# Check USB power
lsusb

# Check kernel messages
dmesg | grep -i usb

# Try different USB port (USB 3.0 can have interference with some devices)
```

### Network issues
```bash
# Check connectivity
ping 8.8.8.8
ping github.com

# Check DNS
nslookup github.com

# Check routes
ip route
```

## Ansible Roles Reference

The `pi-setup/ansible/playbook.yml` performs:

1. **System preparation**
   - Package updates
   - Required package installation
   - Kernel parameter configuration

2. **Storage setup**
   - NVMe detection and mounting
   - Storage directory creation

3. **K3s installation**
   - Master node initialization
   - Worker node joining
   - Kubeconfig distribution

4. **Post-install**
   - Helm installation
   - Namespace creation
   - Status verification

## Next Steps

After Pi provisioning:

1. **Register with Rancher** (from management cluster)
2. **Apply Fleet GitRepo** for automatic deployments
3. **Deploy Home Assistant** via GitOps
4. **Configure monitoring** via Prometheus/Grafana
