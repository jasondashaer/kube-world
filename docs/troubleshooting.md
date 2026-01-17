# Troubleshooting Guide

## Common Issues

### Bootstrap Failures

#### "Cannot connect to Kubernetes cluster"

**Symptoms:**
```
ERROR: Cannot connect to Kubernetes cluster
```

**Solutions:**
1. Check if Docker Desktop is running (Mac)
2. Verify KIND cluster exists: `kind get clusters`
3. Check kubeconfig: `kubectl config current-context`

```bash
# Reset and retry
./bootstrap.sh --cleanup
./bootstrap.sh
```

#### "Helm repo not found"

**Symptoms:**
```
Error: repo rancher-stable not found
```

**Solution:**
```bash
helm repo add rancher-stable https://releases.rancher.com/server-charts/stable
helm repo update
```

### Raspberry Pi Issues

#### K3s fails to start

**Symptoms:**
```
Job for k3s.service failed
```

**Debug:**
```bash
# Check service status
sudo systemctl status k3s

# View logs
sudo journalctl -u k3s -f

# Check cgroup configuration
cat /proc/cmdline | grep cgroup
```

**Solution:**
Ensure cgroup memory is enabled:
```bash
# Add to /boot/firmware/cmdline.txt
cgroup_memory=1 cgroup_enable=memory

# Reboot
sudo reboot
```

#### "Permission denied" for USB devices

**Symptoms:**
Home Assistant can't access Z-Wave/Zigbee USB devices

**Solution:**
```bash
# Add user to dialout group
sudo usermod -aG dialout $(whoami)

# Set device permissions
sudo chmod 666 /dev/ttyUSB0
sudo chmod 666 /dev/ttyACM0

# Persistent udev rule
echo 'SUBSYSTEM=="tty", ATTRS{idVendor}=="0658", ATTRS{idProduct}=="0200", MODE="0666"' | \
  sudo tee /etc/udev/rules.d/99-usb-serial.rules
sudo udevadm control --reload-rules
```

### Rancher Issues

#### "Rancher pods stuck in ContainerCreating"

**Debug:**
```bash
kubectl -n cattle-system describe pod rancher-xxxxx
kubectl -n cattle-system logs rancher-xxxxx
```

**Common causes:**
1. cert-manager not ready
2. Insufficient resources
3. Image pull issues

**Solution:**
```bash
# Ensure cert-manager is ready
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=300s

# Check events
kubectl -n cattle-system get events --sort-by='.lastTimestamp'
```

#### Can't access Rancher UI

**For local development:**
```bash
# Port forward
kubectl -n cattle-system port-forward svc/rancher 8443:443

# Access at https://localhost:8443
```

### Fleet/GitOps Issues

#### "GitRepo not syncing"

**Debug:**
```bash
# Check GitRepo status
kubectl -n fleet-local get gitrepo
kubectl -n fleet-local describe gitrepo kube-world

# Check Fleet controller logs
kubectl -n cattle-fleet-system logs -l app=fleet-controller
```

**Common causes:**
1. Repository not accessible
2. Invalid YAML in manifests
3. Branch mismatch

#### "Bundle stuck in NotReady"

**Debug:**
```bash
kubectl -n fleet-local get bundle
kubectl -n fleet-local describe bundle <bundle-name>
```

### Network Issues

#### Pods can't reach external services

**Debug:**
```bash
# Test DNS
kubectl run test --rm -it --image=busybox -- nslookup github.com

# Test connectivity
kubectl run test --rm -it --image=busybox -- wget -O- https://github.com
```

**Solution (K3s):**
```bash
# Check CoreDNS
kubectl -n kube-system get pods -l k8s-app=kube-dns

# Restart CoreDNS
kubectl -n kube-system rollout restart deployment coredns
```

### Storage Issues

#### PVC stuck in Pending

**Debug:**
```bash
kubectl describe pvc <pvc-name>
kubectl get storageclass
```

**Solution (K3s):**
```bash
# Verify local-path-provisioner
kubectl -n kube-system get pods -l app=local-path-provisioner

# Check provisioner logs
kubectl -n kube-system logs -l app=local-path-provisioner
```

### Secrets Issues

#### "SOPS failed to decrypt"

**Symptoms:**
```
Failed to get the data key required to decrypt the SOPS file
```

**Solution:**
```bash
# Verify age key is configured
echo $SOPS_AGE_KEY_FILE

# Test decryption
sops -d secrets/secrets.enc.yaml

# Regenerate key if lost (will require re-encrypting all secrets)
age-keygen -o ~/.sops/key.txt
```

## Diagnostic Commands

### Cluster Health

```bash
# Overall cluster status
kubectl get nodes -o wide
kubectl get pods --all-namespaces

# Resource usage
kubectl top nodes
kubectl top pods --all-namespaces

# Events (last hour)
kubectl get events --all-namespaces --sort-by='.lastTimestamp' | tail -50
```

### Component Status

```bash
# Rancher
kubectl -n cattle-system get pods
kubectl -n cattle-system logs deploy/rancher

# Fleet
kubectl -n cattle-fleet-system get pods
kubectl -n fleet-local get gitrepo,bundle

# cert-manager
kubectl -n cert-manager get pods
kubectl -n cert-manager get certificates --all-namespaces
```

### Network Debugging

```bash
# DNS resolution
kubectl run test --rm -it --image=busybox -- nslookup kubernetes.default

# Pod-to-pod connectivity
kubectl run test1 --rm -it --image=busybox -- ping <other-pod-ip>

# Service connectivity
kubectl run test --rm -it --image=busybox -- wget -O- http://kubernetes.default.svc
```

## Log Collection

### Collect all logs for debugging

```bash
# Create debug bundle
mkdir -p /tmp/kube-debug
kubectl cluster-info dump --output-directory=/tmp/kube-debug

# Specific component logs
kubectl -n cattle-system logs deploy/rancher > /tmp/kube-debug/rancher.log
kubectl -n kube-system logs -l k8s-app=kube-dns > /tmp/kube-debug/coredns.log

# Compress for sharing
tar -czf kube-debug.tar.gz /tmp/kube-debug
```

## Recovery Procedures

### Complete Cluster Rebuild

```bash
# Backup any critical data first!

# Full cleanup and rebuild
./bootstrap.sh --cleanup
./bootstrap.sh --verbose

# Verify
kubectl get nodes
kubectl get pods --all-namespaces
```

### Restore from Velero Backup (when implemented)

```bash
# List backups
velero backup get

# Restore specific backup
velero restore create --from-backup <backup-name>

# Restore specific namespace
velero restore create --from-backup <backup-name> --include-namespaces home-assistant
```

## Getting Help

1. Check this troubleshooting guide
2. Review logs with commands above
3. Search [K3s issues](https://github.com/k3s-io/k3s/issues)
4. Search [Rancher issues](https://github.com/rancher/rancher/issues)
5. Open an issue in this repository with:
   - Platform (Mac/Pi/Cloud)
   - Bootstrap command used
   - Error messages
   - Relevant logs
