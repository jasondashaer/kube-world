# CLAUDE.md - AI Assistant Guide for kube-world

## Project Overview

kube-world is an ephemeral, cloud-agnostic Kubernetes orchestration framework for deploying clusters across Raspberry Pi, macOS (development), and cloud environments. It uses a single `bootstrap.sh` entry point, GitOps via Fleet, and central management via Rancher.

**Repository**: `https://github.com/jasondashaer/kube-world.git`
**License**: MIT
**Primary branch**: `main`

## Repository Structure

```
kube-world/
├── bootstrap.sh              # Main entry point (single-command setup, ~750 lines)
├── config.yaml               # Central configuration (single source of truth)
├── .sops.yaml                # SOPS encryption rules (age-based)
├── .yamllint.yml             # YAML linting rules (max line 120, 2-space indent)
├── .github/workflows/ci.yml  # CI pipeline (lint, validate, scan, test)
├── apps/                     # Kubernetes application manifests
│   ├── base/                 # Shared resources (namespaces, quotas)
│   │   ├── namespaces.yaml   # Namespace definitions
│   │   └── fleet.yaml        # Fleet bundle config for base
│   ├── home-assistant/       # Home Assistant deployment
│   │   ├── deployment.yaml   # Main HA deployment manifest
│   │   ├── udev-rules.yaml   # USB device rules for IoT
│   │   └── fleet.yaml        # Fleet bundle config
│   └── velero/               # Backup configuration
│       ├── velero-config.yaml
│       └── fleet.yaml
├── clusters/                 # Cluster definitions
│   ├── mac-local.yaml        # KIND cluster (3-node: 1 control + 2 workers)
│   └── pi-cluster.yaml       # K3s cluster for Raspberry Pi
├── docs/
│   ├── architecture.md       # Hub-and-spoke design, data flow diagrams
│   └── troubleshooting.md    # Common issues and debug commands
├── gitops/
│   └── fleet.yaml            # Fleet GitRepo + ClusterGroup definitions
├── infrastructure/           # Terraform modules (multi-cloud)
│   ├── terraform.tf          # Providers: AWS, GCP, Azure, K8s, Helm
│   ├── variables.tf          # Cloud-agnostic variables
│   └── modules/
│       ├── dns/              # DNS management module
│       └── storage/          # Backup storage module
├── inventory/
│   └── hardware.yaml         # Hardware registry (nodes, IoT devices)
├── pi-setup/                 # Raspberry Pi provisioning
│   ├── ansible/
│   │   ├── playbook.yml      # Main playbook (~462 lines, 7 plays)
│   │   ├── ansible.cfg       # SSH reliability tuning for WiFi
│   │   └── inventory.ini     # Node inventory
│   ├── cloud-init/           # Zero-touch Pi configuration
│   └── scripts/              # Helper scripts
├── policies/
│   ├── kyverno-policies.yaml # 5 cluster policies (labels, privilege, limits, registries, network)
│   └── scheduling-priorities.yaml  # PriorityClasses and affinity examples
├── rancher/
│   ├── install-rancher.sh    # Rancher + cert-manager + ingress setup
│   └── account-management.sh # User/RBAC management
├── secrets/
│   ├── README.md             # SOPS setup guide
│   └── secrets.template.yaml # Template for secrets
└── cost-evaluation/          # Cost optimization framework
    └── crd/                  # Custom resource definitions
```

## Key Technologies

| Technology | Version | Purpose |
|-----------|---------|---------|
| K3s | v1.29.0+k3s1 | Lightweight Kubernetes for Pi/edge |
| KIND | latest | Local dev clusters on Mac (Docker-based) |
| Rancher | 2.13.1 | Central management UI and API |
| Fleet | (bundled with Rancher) | GitOps continuous deployment |
| Helm | 3.14.0 | Kubernetes package manager |
| Ansible | latest | Pi provisioning and config management |
| Terraform | 1.6.0+ | Cloud infrastructure (AWS/GCP/Azure) |
| SOPS + age | latest | Secrets encryption in Git |
| Kyverno | latest | Policy enforcement |
| cert-manager | v1.14.0 | TLS certificate management |

## Architecture

Hub-and-spoke model:
- **Management cluster** (Mac KIND or cloud): Runs Rancher + Fleet
- **Workload clusters** (Pi K3s, cloud EKS/GKE): Run applications
- **GitOps flow**: Git commit -> Fleet detects -> creates Bundle -> targets matching clusters -> agent applies manifests

All configuration lives in Git. Fleet polls every 15-30 seconds for changes in `apps/`, `policies/`, and `gitops/` paths.

## Build, Test, and Lint Commands

### Bootstrap (full cluster setup)

```bash
# Auto-detect platform
./bootstrap.sh

# Mac development (requires Docker Desktop running)
./bootstrap.sh --platform mac --mode dev --verbose

# Raspberry Pi
./bootstrap.sh --platform pi --mode dev --verbose

# Dry run (preview only)
./bootstrap.sh --dry-run --platform mac

# Clean and rebuild
./bootstrap.sh --cleanup && ./bootstrap.sh
```

### Validation and Linting

```bash
# YAML linting (uses .yamllint.yml config)
yamllint -c .yamllint.yml .

# Shell script linting
shellcheck bootstrap.sh rancher/install-rancher.sh

# Kubernetes manifest validation
find apps/ -name '*.yaml' -type f | xargs kubeconform -summary -strict -ignore-missing-schemas
find policies/ -name '*.yaml' -type f | xargs kubeconform -summary -strict -ignore-missing-schemas

# Ansible playbook linting
ansible-lint pi-setup/ansible/playbook.yml

# Dry-run manifest application
kubectl apply --dry-run=client -f apps/

# Security scan (Trivy)
trivy config .
```

### Ansible (Pi provisioning)

```bash
# Run the full Pi setup playbook
ansible-playbook -i pi-setup/ansible/inventory.ini pi-setup/ansible/playbook.yml

# With extra vars
ansible-playbook -i pi-setup/ansible/inventory.ini pi-setup/ansible/playbook.yml \
    -e "k3s_version=v1.29.0+k3s1" -e "mode=dev"
```

### Terraform (cloud infrastructure)

```bash
cd infrastructure
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

### Secrets management

```bash
# Encrypt a file
sops -e -i secrets/my-secret.yaml

# Decrypt a file
sops -d secrets/my-secret.yaml

# Edit encrypted file in place
sops secrets/my-secret.yaml

# Set key location
export SOPS_AGE_KEY_FILE=~/.sops/key.txt
```

## CI Pipeline

Defined in `.github/workflows/ci.yml`, triggered on push/PR to `main`:

1. **Lint**: yamllint + ShellCheck
2. **Validate K8s Manifests**: kubeconform with `--strict --ignore-missing-schemas`
3. **Ansible Lint**: ansible-lint on `pi-setup/ansible/playbook.yml`
4. **Security Scan**: Trivy config scan, SARIF output to GitHub Security
5. **Test Bootstrap**: `./bootstrap.sh --dry-run --platform mac` on macOS runner

## Code Conventions

### Shell Scripts

- Use `set -euo pipefail` and `IFS=$'\n\t'` at the top
- Logging functions: `log()` (green INFO), `warn()` (yellow WARN), `error()` (red ERROR), `debug()` (blue DEBUG, verbose-only)
- Function naming: `snake_case` (e.g., `install_prereqs_mac`, `wait_for_crd`)
- Source scripts with `source` and call their `main()` when used as libraries (see `install_rancher()` in bootstrap.sh)
- Guard direct execution: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`
- Version variables as env var overrides: `VAR="${VAR:-default}"`

### YAML Files

- 2-space indentation (enforced by `.yamllint.yml`)
- Max line length: 120 characters (warning level)
- Comments require a starting space
- Truthy values: only `true`, `false`, `yes`, `no`
- Document start markers (`---`) are not required

### Kubernetes Manifests

- Always include `app.kubernetes.io/name` label (enforced by Kyverno)
- Always include `app.kubernetes.io/part-of: kube-world` label on infrastructure resources
- Specify resource requests and limits on all containers
- Use PriorityClasses for workload scheduling:
  - `critical-system` (1000000): System components
  - `iot-realtime` (900000): Home Assistant, MQTT
  - `monitoring` (800000): Observability
  - `standard` (500000): Default
  - `batch-low` (100000): Background jobs, non-preemptible
- Use trusted image registries only: `ghcr.io`, `docker.io/library`, `docker.io/rancher`, `registry.k8s.io`
- Use Kyverno `validationFailureAction: Audit` in dev, `Enforce` in prod

### Node Labels and Scheduling

```yaml
# Standard labels used in the project
node.kubernetes.io/role: master | worker
topology.kubernetes.io/zone: edge | local | cloud
workload-type: iot | development | general
hardware: raspberry-pi-5 | raspberry-pi | amd64
```

- IoT workloads: prefer `workload-type=iot` nodes, then `topology.kubernetes.io/zone=edge`
- Compute workloads: prefer `topology.kubernetes.io/zone=local|cloud`, then `kubernetes.io/arch=amd64`
- HA workloads: use pod anti-affinity on `kubernetes.io/hostname`

### Ansible Conventions

- Remote user: `admin`
- Privilege escalation: `sudo` without password
- SSH tuning for WiFi: ControlMaster, ServerAliveInterval=15s, ConnectTimeout=30s
- Each play re-establishes SSH connections to handle WiFi drops
- Package installations batched to avoid resource exhaustion on Pi
- Long-running tasks use async with explicit timeouts
- Retries with delays for network-dependent operations
- Forks limited to 5 for Pi stability

### Configuration

- `config.yaml` is the single source of truth for all configurable parameters
- Sections: `deployment`, `network`, `nodes`, `iot_devices`, `cloud`, `dns`, `backup`, `security`, `repository`
- Fields marked `[SOPS]` must be encrypted before committing
- Fields marked `[UPDATE]` require user customization

### Secrets

- Encrypted with SOPS using age encryption
- Public key: `age19grykgll3ugdtt0z98p4j0qefrt6alqesnwsw7gwj8kteamt2swslppqtc`
- Encryption rules in `.sops.yaml`:
  - `config.yaml`: encrypts fields matching `^(password|secret|key|token)$`
  - `secrets/*.yaml`: full file encryption
  - `*secret*.yaml`: encrypts `data` and `stringData` fields
  - `*.env`: full file encryption
- Private keys (`age.key`, `key.txt`) are gitignored and must never be committed

### GitOps (Fleet)

- Fleet bundle configs use `fleet.yaml` in each app directory (not standard K8s resources)
- `fleet.yaml` files have no `apiVersion`/`kind` - they are Fleet-specific
- GitRepo definitions in `gitops/fleet.yaml` target clusters by labels
- Two GitRepos: `kube-world` (local management) and `kube-world-edge` (edge devices)
- ClusterGroups: `edge-devices` (zone=edge) and `home-automation` (workload-type=iot)

## Supported Platforms

| Platform | K8s Distribution | Status |
|----------|-----------------|--------|
| macOS (ARM64/x86) | KIND | Supported |
| Raspberry Pi 5 | K3s | Supported |
| Raspberry Pi 4 | K3s | Supported |
| Linux (x86/ARM) | K3s | Supported |
| AWS EKS | EKS | Planned |
| GCP GKE | GKE | Planned |

## Common Patterns for Changes

### Adding a new application

1. Create directory under `apps/<app-name>/`
2. Add `deployment.yaml` (or other K8s manifests) with required labels and resource limits
3. Add `fleet.yaml` bundle config for Fleet targeting
4. Add the path to `gitops/fleet.yaml` under `spec.paths`
5. If the app needs a namespace, add it to `apps/base/namespaces.yaml`

### Adding a new Pi node

1. Update `pi-setup/ansible/inventory.ini` with the node's IP
2. Update `config.yaml` under `nodes.pi_nodes` with MAC and IP
3. Update `network.static_ips` in `config.yaml`
4. Update `inventory/hardware.yaml`
5. Run the Ansible playbook

### Adding a new Kyverno policy

1. Add the policy to `policies/kyverno-policies.yaml` (or a new file in `policies/`)
2. Use `Audit` mode for development, `Enforce` for production
3. Exclude system namespaces as needed (`kube-system`, `cattle-system`, `fleet-*`)

### Modifying cluster configuration

- Mac (KIND): Edit `clusters/mac-local.yaml`
- Pi (K3s): Edit `clusters/pi-cluster.yaml` and `pi-setup/ansible/playbook.yml`
- Central config: Edit `config.yaml` (versions, features, network settings)

## Files to Avoid Modifying Without Understanding

- `.sops.yaml` - Breaking this breaks all secrets encryption/decryption
- `bootstrap.sh` main() flow - The execution order is critical (prereqs -> preflight -> cluster -> rancher -> gitops -> apps -> verify)
- `rancher/install-rancher.sh` - Sourced by bootstrap.sh; the `main()` function is called programmatically
- Fleet CRD wait logic in `bootstrap.sh` - Timing-sensitive; Fleet CRDs are installed asynchronously by Rancher
- `pi-setup/ansible/ansible.cfg` SSH settings - Tuned specifically for WiFi reliability

## Debugging

### Cluster issues
```bash
kubectl get nodes -o wide
kubectl get pods --all-namespaces
kubectl get events --all-namespaces --sort-by='.lastTimestamp' | tail -50
```

### Rancher issues
```bash
kubectl -n cattle-system get pods
kubectl -n cattle-system logs deploy/rancher
kubectl -n cattle-system port-forward svc/rancher 8443:443  # local access
```

### Fleet/GitOps issues
```bash
kubectl -n fleet-local get gitrepo
kubectl -n fleet-local describe gitrepo kube-world
kubectl -n cattle-fleet-system logs -l app=fleet-controller
kubectl -n fleet-local get bundle
```

### Pi connectivity issues
```bash
# SSH reliability is the most common issue - WiFi power save causes drops
# The Ansible config disables WiFi power save: iw dev wlan0 set power_save off
# Check ansible.cfg for SSH tuning parameters
```

Full troubleshooting guide: `docs/troubleshooting.md`

## Recent Development Focus

Recent commits have focused on production reliability, particularly:
- Ansible conditional boolean type fixes in playbook
- Ansible callback plugin compatibility with community.general 12.0.0+
- SSH reliability improvements for Pi WiFi connections
- Rancher installation and cleanup fixes

## Project Status

### Completed
- Bootstrap script with platform detection
- KIND cluster for Mac, K3s for Pi
- Rancher + Fleet installation
- Home Assistant deployment with IoT support
- Kyverno security policies
- SOPS secrets management
- Central config.yaml
- Cloud-agnostic Terraform modules
- Hardware inventory system
- Velero backup configuration

### In Progress / Planned
- Prometheus/Grafana monitoring stack
- AWS EKS provisioning
- GCP GKE provisioning
- Karmada multi-cluster federation
- Longhorn distributed storage
- Let's Encrypt TLS (currently self-signed)
