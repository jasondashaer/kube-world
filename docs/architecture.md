# kube-world Architecture

## Overview

kube-world implements a hub-and-spoke architecture with GitOps at its core, enabling unified management of distributed Kubernetes clusters.

```
                                    ┌─────────────────────────────────────┐
                                    │           GitHub Repository          │
                                    │         (Single Source of Truth)     │
                                    └─────────────────┬───────────────────┘
                                                      │
                                                      │ GitOps (Fleet)
                                                      ▼
                    ┌─────────────────────────────────────────────────────────────┐
                    │                    Management Cluster                        │
                    │                   (Mac/Cloud/Any K8s)                        │
                    │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
                    │  │   Rancher   │  │    Fleet    │  │    cert-manager     │  │
                    │  │   (UI/API)  │  │  (GitOps)   │  │   (TLS certs)       │  │
                    │  └──────┬──────┘  └──────┬──────┘  └─────────────────────┘  │
                    └─────────┼────────────────┼──────────────────────────────────┘
                              │                │
              ┌───────────────┼────────────────┼───────────────┐
              │               │                │               │
              ▼               ▼                ▼               ▼
    ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
    │   Pi Cluster    │ │   Mac Cluster   │ │  Cloud Cluster  │ │  Future Cluster │
    │    (Edge/IoT)   │ │     (Dev)       │ │   (Production)  │ │                 │
    │ ┌─────────────┐ │ │ ┌─────────────┐ │ │ ┌─────────────┐ │ │                 │
    │ │Home Asst.   │ │ │ │  Testing    │ │ │ │  Services   │ │ │                 │
    │ │Z-Wave/Zigbee│ │ │ │  Workloads  │ │ │ │  Workloads  │ │ │                 │
    │ └─────────────┘ │ │ └─────────────┘ │ │ └─────────────┘ │ │                 │
    └─────────────────┘ └─────────────────┘ └─────────────────┘ └─────────────────┘
```

## Core Principles

### 1. GitOps-First

Every configuration change flows through Git:
- Infrastructure definitions in `/clusters/`
- Application manifests in `/apps/`
- Policies in `/policies/`
- Secrets encrypted with SOPS

Fleet monitors the repository and automatically reconciles cluster state.

### 2. Ephemerality

The system is designed for complete recreatability:

```bash
# Destroy everything
./bootstrap.sh --cleanup

# Rebuild from scratch
./bootstrap.sh
```

This enables:
- Disaster recovery
- Environment consistency
- Infrastructure testing
- Reduced operational burden

### 3. Dynamic Scheduling

Workloads are placed based on:

| Factor | Implementation |
|--------|----------------|
| Hardware requirements | Node labels (`hardware=raspberry-pi-5`) |
| Location/latency | Topology labels (`topology.kubernetes.io/zone=edge`) |
| Workload type | Custom labels (`workload-type=iot`) |
| Priority | PriorityClasses (iot-realtime, standard, batch-low) |
| Resource availability | Kubernetes scheduler |

### 4. Platform Abstraction

The same application manifests work across:
- KIND on Mac (development)
- K3s on Pi (edge/IoT)
- EKS/GKE (production)

Platform-specific configurations use Kustomize overlays or Fleet targets.

## Component Deep Dive

### Rancher

- **Role**: Central management plane
- **Features**: Multi-cluster management, RBAC, monitoring
- **Access**: Web UI at `https://rancher.local` or port-forwarded

### Fleet

- **Role**: GitOps continuous deployment
- **Features**: Multi-cluster sync, bundle management, drift detection
- **Config**: `/gitops/fleet.yaml`

### K3s

- **Role**: Lightweight Kubernetes distribution
- **Use**: Edge devices (Pi), development
- **Features**: Single binary, low resource usage, built-in components

### KIND (Kubernetes IN Docker)

- **Role**: Local development clusters
- **Use**: Mac development environment
- **Features**: Multi-node simulation, fast startup

## Data Flow

### Application Deployment

```
1. Developer commits to /apps/home-assistant/
                    │
                    ▼
2. GitHub triggers Fleet webhook (or Fleet polls)
                    │
                    ▼
3. Fleet detects change, creates Bundle
                    │
                    ▼
4. Bundle targets matching clusters (label: workload-type=iot)
                    │
                    ▼
5. Fleet agent on Pi cluster applies manifests
                    │
                    ▼
6. Kubernetes scheduler places pod on appropriate node
                    │
                    ▼
7. Home Assistant runs with USB device access
```

### Secrets Flow

```
1. Create secret from template
2. Encrypt with SOPS (age encryption)
3. Commit encrypted secret to Git
4. Fleet syncs to cluster
5. SOPS/Flux decrypts at deploy time
6. Secret available to workloads
```

## Network Architecture

### Development (Mac)

```
┌─────────────────────────────────────────┐
│              macOS Host                  │
│  ┌───────────────────────────────────┐  │
│  │         Docker Desktop            │  │
│  │  ┌─────────────────────────────┐  │  │
│  │  │      KIND Cluster           │  │  │
│  │  │   ┌─────────┐ ┌─────────┐   │  │  │
│  │  │   │Control  │ │ Worker  │   │  │  │
│  │  │   │ Plane   │ │  Node   │   │  │  │
│  │  │   └────┬────┘ └────┬────┘   │  │  │
│  │  │        └─────┬─────┘        │  │  │
│  │  │              │              │  │  │
│  │  │       Port Mappings         │  │  │
│  │  │    80:80, 443:443, 6443     │  │  │
│  │  └──────────────┼──────────────┘  │  │
│  └─────────────────┼─────────────────┘  │
│                    │                     │
│            localhost:443                 │
└────────────────────┼─────────────────────┘
                     │
              Browser/kubectl
```

### Production (Multi-Site)

```
┌──────────────────┐      ┌──────────────────┐
│   Home Network   │      │   Cloud (AWS)    │
│   192.168.1.0/24 │      │   10.0.0.0/16    │
│                  │      │                   │
│  ┌────────────┐  │      │  ┌────────────┐  │
│  │  Pi (K3s)  │  │      │  │  EKS       │  │
│  │  .100      │◄─┼──────┼─►│  Cluster   │  │
│  └────────────┘  │ VPN/ │  └────────────┘  │
│                  │Tailsc│                   │
│  ┌────────────┐  │ale   │  ┌────────────┐  │
│  │  Mac (Dev) │  │      │  │  RDS       │  │
│  │  .50       │  │      │  │  (Backup)  │  │
│  └────────────┘  │      │  └────────────┘  │
└──────────────────┘      └──────────────────┘
```

## Security Model

### Defense in Depth

1. **Network**: Default-deny policies, isolated namespaces
2. **Identity**: RBAC, service accounts, mTLS (future)
3. **Secrets**: SOPS encryption, no plaintext in Git
4. **Workloads**: Kyverno policies, resource limits
5. **Supply Chain**: Restricted image registries

### Trust Boundaries

```
┌─────────────────────────────────────────────────────────────┐
│                    Management Cluster                        │
│                     (High Trust Zone)                        │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │   Rancher   │  │    Fleet    │  │   Secrets (SOPS)    │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                              │
                    Authenticated API
                              │
┌─────────────────────────────┼───────────────────────────────┐
│                     Workload Clusters                        │
│                    (Segmented Trust)                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  Namespace  │  │  Namespace  │  │     Namespace       │  │
│  │  home-asst  │  │  monitoring │  │     default         │  │
│  │  (IoT priv) │  │  (read-only)│  │   (restricted)      │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

## Scaling Considerations

### Horizontal Scaling

| Component | Single Node | Multi-Node | Multi-Cluster |
|-----------|-------------|------------|---------------|
| K3s | 1 server | 3 servers (HA) | N/A |
| Rancher | 1 replica | 3 replicas | N/A |
| Fleet | Bundled | Bundled | Federated |
| Apps | Per needs | Pod replicas | Cross-cluster |

### Resource Planning

| Platform | Nodes | CPU | Memory | Storage |
|----------|-------|-----|--------|---------|
| Pi 5 (min) | 1 | 4 cores | 8GB | 64GB SD |
| Pi 5 (rec) | 1-3 | 4 cores | 16GB | 256GB NVMe |
| Mac Dev | 1 KIND | 4 cores | 8GB | 50GB |
| Cloud Prod | 3-5 | 8+ cores | 16GB+ | 100GB+ |

## Future Architecture

### Multi-Cluster Federation (Karmada)

```
                    ┌─────────────────────────────────┐
                    │         Karmada Control         │
                    │          (Federation)           │
                    └───────────────┬─────────────────┘
                                    │
            ┌───────────────────────┼───────────────────────┐
            │                       │                       │
            ▼                       ▼                       ▼
    ┌───────────────┐       ┌───────────────┐       ┌───────────────┐
    │   Cluster A   │       │   Cluster B   │       │   Cluster C   │
    │   (US-East)   │       │   (US-West)   │       │   (EU)        │
    └───────────────┘       └───────────────┘       └───────────────┘
```

This enables:
- Workload distribution across regions
- Disaster recovery
- Data locality compliance
- Resource optimization
