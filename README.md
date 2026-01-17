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

- macOS or Linux machine (management workstation)
- Git, Homebrew (macOS), or apt (Linux)
- SSH key pair (`~/.ssh/id_ed25519`)

### One-Command Bootstrap

```bash
# Clone the repository
git clone https://github.com/jasondashaer/kube-world.git
cd kube-world

# Run bootstrap (auto-detects platform)
./bootstrap.sh

# Or specify options
./bootstrap.sh --platform mac --mode dev --verbose
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
- [ ] Prometheus/Grafana monitoring stack
- [ ] Velero backup configuration
- [ ] AWS EKS provisioning
- [ ] GCP GKE provisioning
- [ ] Karmada multi-cluster federation
- [ ] GitHub Actions CI/CD

## 🤝 Contributing

Contributions are welcome! Please read our contributing guidelines (coming soon).

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

**Built with ❤️ for the homelab and edge computing community**