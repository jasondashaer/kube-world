# Hardware Inventory

This directory contains the hardware inventory for the kube-world infrastructure.

## Files

- `hardware.yaml` - Central inventory of all hardware (nodes, IoT devices, network)

## Usage

### View Inventory

```bash
# Pretty print inventory
cat inventory/hardware.yaml | yq

# List all nodes
yq '.nodes[].name' inventory/hardware.yaml

# List IoT devices
yq '.iot_devices[].name' inventory/hardware.yaml
```

### Update Inventory

1. Edit `hardware.yaml` with your actual hardware details
2. Update MAC addresses, IPs, and device paths
3. Set device status to `active` when connected
4. Commit changes to Git

### Generate udev Rules

The inventory can be used to generate udev rules for IoT devices:

```bash
# Generate udev rules from inventory
yq '.iot_devices[] | select(.status == "active") | .udevRule' inventory/hardware.yaml > /tmp/99-iot-devices.rules
sudo cp /tmp/99-iot-devices.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
```

### Integration with Ansible

The inventory is used by Ansible playbooks for:
- Node provisioning
- Device configuration
- Network setup

### Integration with Kubernetes

Future: A custom controller can read this inventory to:
- Apply node labels automatically
- Configure device plugins
- Manage USB passthrough

## Inventory Schema

### Node Fields

| Field | Description | Required |
|-------|-------------|----------|
| `id` | Unique identifier | Yes |
| `name` | Human-readable name | Yes |
| `type` | Node type (development, edge, cloud) | Yes |
| `role` | Kubernetes role (management, master, worker) | Yes |
| `enabled` | Whether node is active | Yes |
| `hardware` | Hardware specifications | Yes |
| `network` | Network configuration | Yes |
| `capabilities` | Node capabilities | No |
| `labels` | Kubernetes labels | No |

### IoT Device Fields

| Field | Description | Required |
|-------|-------------|----------|
| `id` | Unique identifier | Yes |
| `name` | Human-readable name | Yes |
| `type` | Device type (zigbee, zwave, thread) | Yes |
| `status` | Status (planned, active, disabled) | Yes |
| `assignedNode` | Node ID where device is connected | Yes |
| `hardware` | Hardware specifications | Yes |
| `udevRule` | Linux udev rule for device | No |
| `homeAssistant` | HA integration config | No |

## Updating for Your Setup

1. **Update Node MAC Addresses**
   ```bash
   # On Mac
   ifconfig en0 | grep ether
   
   # On Pi
   ip link show eth0
   ```

2. **Update IoT Device IDs**
   ```bash
   # When device is connected
   lsusb  # Find vendor:product ID
   ```

3. **Set Static IPs**
   - Configure DHCP reservations in your router
   - Or set static IPs in cloud-init

## Future Enhancements

- [ ] Auto-discovery of devices
- [ ] Kubernetes CRD for inventory
- [ ] Operator for automatic configuration
- [ ] Integration with OpenCost for resource tracking
