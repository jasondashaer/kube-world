# kube-world 🌍

A comprehensive, ephemeral Kubernetes orchestration framework designed for seamless deployment across platforms - from a single Raspberry Pi to multi-cloud production environments.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![K3s](https://img.shields.io/badge/K3s-v1.29-blue)](https://k3s.io/)
[![Rancher](https://img.shields.io/badge/Rancher-2.8-green)](https://rancher.com/)

## 🎯 Project Goals

- **Ephemerality**: Rebuild entire infrastructure from scratch with a single command
- **Interchangeability**: Seamlessly move workloads between Pi, Mac, and cloud
- **Automation**: Zero-touch provisioning with GitOps-driven deployments
- **Scalability**: From single-node testing to multi-cluster federation
- **Cost-Effective**: Optimize for near-zero costs in dev, scale to production

## 🚀 Quick Start

### Prerequisites

**Required:**
- macOS (Apple Silicon or Intel) or Linux machine
- Git

**For Mac Development (KIND cluster):**
- **Docker Desktop** - [Download here](https://www.docker.com/products/docker-desktop/)
  - Choose "Mac with Apple Chip" for M1/M2/M3 Macs
  - Launch Docker Desktop and wait for it to fully start before running bootstrap

**For Pi Deployment:**
- Raspberry Pi 5 (recommended) or Pi 4 with 4GB+ RAM
- SSH access to Pi

### One-Command Bootstrap

```bash
# Clone the repository
git clone https://github.com/jasondashaer/kube-world.git
cd kube-world

# FIRST: Edit config.yaml with your settings
# - WiFi credentials (for Pi)
# - Static IP reservations
# - Cloud provider settings (optional)

# For Mac development (requires Docker Desktop running)
./bootstrap.sh --platform mac --mode dev --verbose

# For Raspberry Pi
./bootstrap.sh --platform pi --mode dev --verbose

# Or auto-detect platform
./bootstrap.sh
```

### Bootstrap Options

| Flag | Description | Default |
|------|-------------|---------|
| `--platform` | Target: `mac`, `pi`, `cloud` | auto-detect |
| `--mode` | Environment: `dev`, `prod` | `dev` |
| `--skip-prereqs` | Skip tool installation | `false` |
| `--dry-run` | Preview without executing | `false` |
| `--cleanup` | Remove existing setup first | `false` |
| `--verbose` | Enable detailed logging | `false` |

## 📁 Repository Structure

```
kube-world/
├── bootstrap.sh           # Main entry point - single command setup
├── apps/                  # Application deployments
│   ├── base/             # Resources for all clusters
│   ├── home-assistant/   # Home Assistant with IoT support
│   └── monitoring/       # Prometheus, Grafana stack
├── clusters/             # Cluster configurations
│   ├── mac-local.yaml    # KIND config for Mac dev
│   └── pi-cluster.yaml   # K3s config for Raspberry Pi
├── docs/                 # Extended documentation
├── gitops/               # Fleet/GitOps configuration
│   └── fleet.yaml        # GitRepo definitions
├── pi-setup/             # Raspberry Pi provisioning
│   ├── ansible/          # Ansible playbooks and roles
│   ├── cloud-init/       # Zero-touch Pi configuration
│   └── scripts/          # Helper scripts
├── policies/             # Security and scheduling policies
│   ├── kyverno-policies.yaml
│   └── scheduling-priorities.yaml
├── rancher/              # Rancher installation
│   └── install-rancher.sh
├── secrets/              # Encrypted secrets (SOPS)
│   └── README.md         # Secrets management guide
└── .sops.yaml           # SOPS encryption config
```

## 🖥️ Supported Platforms

| Platform | Status | Use Case |
|----------|--------|----------|
| **Mac (ARM64)** | ✅ Supported | Development, testing |
| **Mac (x86)** | ✅ Supported | Development, testing |
| **Raspberry Pi 5** | ✅ Supported | Edge/IoT, Home Assistant |
| **Raspberry Pi 4** | ✅ Supported | Edge/IoT workloads |
| **Linux (x86/ARM)** | ✅ Supported | Servers, VMs |
| **AWS EKS** | 🚧 Planned | Production cloud |
| **GCP GKE** | 🚧 Planned | Production cloud |

## 🏠 Home Assistant Integration

Home Assistant is deployed with full IoT protocol support:

- **Thread/Matter**: For modern smart home devices
- **Z-Wave**: Via USB controller (e.g., Zooz ZST39)
- **Zigbee**: Via USB controller (e.g., Sonoff Zigbee 3.0)
- **Bluetooth**: Direct from Pi

The deployment uses node affinity to prefer running on Raspberry Pi nodes for low-latency device communication.

## 🔐 Security

- **Secrets**: Encrypted with SOPS + age (see `secrets/README.md`)
- **RBAC**: Kubernetes native role-based access control
- **Policies**: Kyverno policies for security enforcement
- **Network**: Default-deny network policies per namespace

## 📊 Monitoring & Observability

- **Rancher**: Central management UI for all clusters
- **Fleet**: GitOps-based continuous deployment
- **Prometheus**: Metrics collection (planned)
- **Grafana**: Visualization dashboards (planned)

## 🔄 Disaster Recovery

- **Velero**: Cluster backup to S3/GCS (planned)
- **GitOps**: All configuration in Git = instant rebuild
- **Ephemeral Design**: `./bootstrap.sh --cleanup && ./bootstrap.sh`

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/architecture.md) | System design and decisions |
| [Pi Setup Guide](pi-setup/README.md) | Raspberry Pi provisioning |
| [Secrets Management](secrets/README.md) | Encryption setup |
| [Troubleshooting](docs/troubleshooting.md) | Common issues |

## 🛠️ Development

### Running Tests

```bash
# Dry run to verify configuration
./bootstrap.sh --dry-run

# Validate Kubernetes manifests
kubectl apply --dry-run=client -f apps/
```

### CI/CD

GitHub Actions workflows (planned):
- YAML linting
- Kubernetes manifest validation
- Security scanning
- Automated testing on PR

## 🗺️ Roadmap

- [x] Bootstrap script with platform detection
- [x] KIND cluster for Mac development
- [x] K3s cluster for Raspberry Pi
- [x] Rancher installation with Fleet
- [x] Home Assistant deployment
- [x] Kyverno security policies
- [x] SOPS secrets management
- [x] Central configuration (config.yaml)
- [x] Cloud-agnostic Terraform modules
- [x] Velero multi-backend backup config
- [x] Hardware inventory system
- [ ] Prometheus/Grafana monitoring stack
- [ ] AWS EKS provisioning
- [ ] GCP GKE provisioning
- [ ] Karmada multi-cluster federation
- [ ] GitHub Actions CI/CD

## ⚙️ Configuration

All settings are centralized in `config.yaml`:

| Section | Purpose |
|---------|---------|
| `deployment` | Mode, platform, versions, feature flags |
| `network` | Home network, static IPs, WiFi settings |
| `nodes` | MacBook and Pi node inventory |
| `iot_devices` | Zigbee, Z-Wave, Thread controllers |
| `cloud` | AWS/GCP/Azure provider settings |
| `backup` | Velero backup destinations |
| `security` | SOPS keys, SSH, TLS settings |

Edit `config.yaml` before running bootstrap to customize your deployment.

## 🤝 Contributing

Contributions are welcome! Please read our contributing guidelines (coming soon).

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

**Built with ❤️ for the homelab and edge computing community**