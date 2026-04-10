# CLAUDE.md - AI Assistant Guide for kube-world

## Project Overview

kube-world is a multi-cluster Kubernetes orchestration framework. It deploys independent K3s clusters across Raspberry Pi edge devices, using Karmada for multi-cluster scheduling, Flux for GitOps, Rancher for management UI, and Zitadel for identity/SSO. Designed for zero-touch deployment: `git push` drives all changes.

**Repository**: `https://github.com/jasondashaer/kube-world.git`
**GitLab mirror**: `http://gitlab.kubew.dev/root/kube-world` (Flux source of truth)
**License**: MIT | **Branch**: `main`

## Architecture

```
GitLab (source of truth) --> Flux (GitOps) --> Karmada API (scheduling) --> Edge Clusters
                                          |                                      |
                                          +--> Edge infra (Traefik, cert-mgr,    |
                                               ExternalDNS) via kubeConfig       |
                                                                                 |
                                Rancher (UI/monitoring) -------------------------+
                                Zitadel (identity/SSO) ---> All services
```

### Key Principles
- **Each Pi is an independent K3s cluster** (not nodes in one cluster) for failure isolation
- **Per-cluster ingress**: each cluster runs its own Traefik + cert-manager + ExternalDNS
- **Per-cluster subdomains**: `*.edge1.kubew.dev` → Tailscale MagicDNS of that cluster
- **GitOps-managed**: edge infrastructure (Traefik, cert-manager, ExternalDNS, Gateway, HTTPRoutes) managed by Flux
- **Zero manual steps**: bootstrap runs to completion without human intervention, including OIDC SSO

### DNS Architecture
- Cloudflare manages `kubew.dev` zone with CNAME records → Tailscale MagicDNS
- `*.kubew.dev` → `pi-central.<tailnet>.ts.net` (central services)
- `*.edge1.kubew.dev` → `pi-edge-1.<tailnet>.ts.net` (edge1 apps)
- Each new cluster gets one wildcard CNAME; apps route by hostname
- ExternalDNS on each cluster can auto-create individual records

### Identity (Zitadel SSO)
- Zitadel at `auth.kubew.dev` — OIDC identity provider
- Rancher OIDC: fully automated via kubectl patch (no browser step)
- Home Assistant OIDC: native `hass-oidc-auth` component, installed by init container
- GitLab OIDC: configured at install via `/etc/gitlab/gitlab.rb.d/oidc.rb`
- Grafana OIDC: pre-created client, ready for Phase 4

### Self-hosted GitLab
GitLab CE runs as a native install on pi-central (arm64, not containerized). Flux watches the GitLab repo for changes. Bootstrap pushes the repo to GitLab and creates deploy tokens for Flux.

## Repository Structure

```
kube-world/
├── bootstrap.sh              # Main orchestration (~3200 lines)
├── config.yaml               # Central configuration (versions, cluster defs)
├── renovate.json5             # Renovate config for auto dependency updates
│
├── apps/                              # Application manifests (Karmada-propagated)
│   ├── base/namespaces.yaml          # Shared namespaces + quotas
│   ├── home-assistant/               # HA + OIDC init container + ConfigMap
│   ├── companion/                    # Bitfocus Companion (streaming control)
│   ├── nodered/                      # Node-RED (visual automations)
│   ├── mosquitto/                    # MQTT broker
│   ├── zigbee2mqtt/                  # Zigbee device bridge
│   ├── esphome/                      # ESP firmware builder
│   ├── code-server/                  # Web IDE for HA config
│   ├── influxdb/                     # Time-series sensor data
│   ├── gitlab/                       # GitLab service/endpoints
│   ├── zitadel/                      # Zitadel HTTPRoutes
│   └── velero/                       # Backup configuration
│
├── infrastructure/                    # Cluster infrastructure
│   ├── clusters/                     # Per-cluster Flux-managed infra
│   │   └── edge1/
│   │       ├── helm/                 # HelmReleases (Traefik, cert-manager, ExternalDNS)
│   │       └── raw/                  # Raw K8s resources (Gateway, certs, HTTPRoutes)
│   ├── traefik/values.yaml           # Shared Traefik Helm values
│   ├── gateway/gateway.yaml          # Gateway resource template
│   ├── cert-manager/                 # ClusterIssuer + Certificate templates
│   ├── external-dns/values.yaml      # ExternalDNS Helm values template
│   ├── zitadel/                      # Zitadel + PostgreSQL HelmReleases
│   ├── modules/                      # Terraform modules
│   │   ├── cloudflare-dns/           # DNS zone + CNAME management
│   │   └── tailscale/                # Auth key management
│   ├── terraform.tf                  # Terraform providers (Cloudflare, Tailscale)
│   ├── variables.tf                  # Terraform variables
│   └── main.tf                       # Module composition
│
├── karmada/                           # Multi-cluster scheduling
│   ├── propagation-policies/         # Where workloads go
│   │   ├── home-assistant.yaml       # HA + OIDC + udev → IoT clusters
│   │   ├── companion.yaml            # Companion → IoT clusters
│   │   ├── iot-apps.yaml             # Node-RED, MQTT, Z2M, ESPHome, etc.
│   │   └── base.yaml                 # Namespaces → all clusters
│   └── override-policies/
│       └── pi-overrides.yaml         # Resource limits for Pi (Deployment/DaemonSet only)
│
├── flux/                              # GitOps configuration
│   ├── sources/git-repository.yaml   # Points to GitLab repo
│   └── kustomizations/
│       ├── apps.yaml                  # App Kustomizations (16 apps)
│       ├── karmada-policies.yaml      # Propagation + override policies
│       ├── policies.yaml              # Kyverno + scheduling
│       ├── identity.yaml              # Zitadel HelmReleases
│       └── infrastructure-edge1.yaml  # Edge1 infra (helm + raw)
│
├── scripts/                           # Operational tooling
│   ├── seed-zitadel.sh               # Identity seed (users, OIDC apps, roles)
│   ├── finalize-oidc.sh              # Rancher group → role mappings
│   ├── install-gitlab.sh             # GitLab CE native install
│   ├── self-provision.sh             # Pi self-provisioning (cloud-init)
│   ├── run-renovate.sh               # Renovate bot runner
│   ├── health-check.sh               # Infrastructure diagnostics
│   └── recover.sh                    # Failure recovery
│
├── pi-setup/                          # Pi provisioning
│   ├── ansible/playbook.yml          # K3s + Tailscale install
│   ├── cloud-init/user-data.yaml     # Zero-touch Pi config + self-provision
│   ├── inventory.ini                  # Pi inventory (central + edge)
│   └── scripts/                       # WiFi stability, self-provision
│
├── rancher/                           # Rancher management
│   ├── install-rancher.sh            # Install with LAN auto-detect
│   └── import-cluster.sh             # Import cluster helper
│
└── policies/                          # Kyverno + scheduling priorities
```

## Key Technologies

| Technology | Version | Purpose |
|-----------|---------|---------|
| K3s | v1.34.6+k3s1 | Lightweight Kubernetes for Pi/edge and central |
| Karmada | 1.17.0 | Multi-cluster scheduling and workload propagation |
| Flux | 2.4.0 | GitOps — watches GitLab, applies to Karmada + edge clusters |
| Rancher | 2.13.1 | Management UI, RBAC, monitoring |
| Zitadel | v4.13.0 (chart 9.28.0) | Identity provider, OIDC SSO for all services |
| Traefik | v3.6.12 (chart 39.x) | Ingress controller, Gateway API, per-cluster |
| cert-manager | v1.20.1 | TLS certificates (Let's Encrypt DNS-01 via Cloudflare) |
| ExternalDNS | v0.20.0 | Auto-creates Cloudflare DNS from HTTPRoutes |
| Tailscale | latest | Mesh VPN between all clusters |
| Terraform | 1.6.0+ | External resources (Cloudflare DNS, Tailscale auth keys) |
| Ansible | latest | Pi hardware provisioning |
| Helm | 3.14.0 | Kubernetes package manager |

## Services and URLs

### Central cluster (pi-central)
| Service | URL | Purpose |
|---------|-----|---------|
| Rancher | `rancher.kubew.dev` | Cluster management UI |
| Zitadel | `auth.kubew.dev` | Identity provider / SSO |
| GitLab | `gitlab.kubew.dev` | Git hosting, Flux source |

### Edge cluster (pi-edge-1)
| Service | URL | Purpose |
|---------|-----|---------|
| Home Assistant | `ha.edge1.kubew.dev` | Smart home automation |
| Companion | `companion.edge1.kubew.dev` | Streaming/AV control |
| Node-RED | `nodered.edge1.kubew.dev` | Visual automation builder |
| Zigbee2MQTT | `zigbee.edge1.kubew.dev` | Zigbee device bridge |
| ESPHome | `esphome.edge1.kubew.dev` | ESP firmware builder |
| VS Code Server | `code.edge1.kubew.dev` | Web IDE for HA config |
| InfluxDB | `influxdb.edge1.kubew.dev` | Time-series sensor data |
| Mosquitto | Internal (port 1883) | MQTT message broker |

## Bootstrap

The bootstrap is fully automated — zero manual steps:

```bash
source .env.bootstrap
./bootstrap.sh --platform pi --stack karmada --verbose
```

Pipeline: Ansible → K3s → Tailscale → Traefik → Gateway → Karmada → edge join → Rancher → cert-manager → LE cert → Zitadel → OIDC enable → GitLab → Flux → ExternalDNS → edge secrets → Flux reconciles edge infra → apps deploy

### What bootstrap.sh handles (imperative, one-time):
- Ansible provisioning of Pis
- K3s + Tailscale installation
- Karmada control plane + edge cluster registration
- Rancher install + OIDC enable (automated via kubectl patch)
- Zitadel Helm install + identity seeding
- GitLab native install + repo push
- Flux install + GitRepository + Kustomizations
- Edge cluster secrets (kubeconfig, Cloudflare tokens, placeholder TLS)
- Cloudflare wildcard CNAMEs

### What Flux handles (GitOps, continuous):
- All app deployments (via Karmada propagation)
- Edge infrastructure (Traefik, cert-manager, ExternalDNS, Gateway, HTTPRoutes)
- Karmada policies (propagation + overrides)
- Kyverno policies + scheduling priorities

## Adding a New Application

1. Create `apps/<app-name>/deployment.yaml` with labels and resource limits
2. Create `apps/<app-name>/kustomization.yaml` referencing deployment.yaml
3. Add Karmada PropagationPolicy in `karmada/propagation-policies/`
4. Add Flux Kustomization in `flux/kustomizations/apps.yaml`
5. Add HTTPRoute in `infrastructure/clusters/edge1/raw/httproutes/`
6. `git push` to GitLab — Flux deploys automatically

## Adding a New Edge Cluster

1. Add to `pi-setup/inventory.ini` and `config.yaml` (with subdomain)
2. Create `infrastructure/clusters/<edge>/` (copy from edge1, update subdomain)
3. Create `flux/kustomizations/infrastructure-<edge>.yaml`
4. `terraform apply` — creates Cloudflare wildcard CNAME
5. Run bootstrap (or self-provision via cloud-init)
6. Flux deploys full infrastructure stack automatically

## Code Conventions

### Shell Scripts
- `set -euo pipefail`
- Logging: `log()` green, `warn()` yellow, `error()` red, `debug()` blue/verbose-only
- Function naming: `snake_case`
- Non-critical functions use `|| warn` not `|| exit`

### YAML
- 2-space indent, max 120 chars
- Required labels: `app.kubernetes.io/name`, `app.kubernetes.io/part-of: kube-world`
- Resource requests and limits on all containers
- Trusted registries: `ghcr.io`, `docker.io/library`, `docker.io/rancher`, `registry.k8s.io`, `quay.io`

### Karmada
- PropagationPolicy: namespace-scoped, targets `workload-type=iot` for edge apps
- ClusterOverridePolicy: scoped to Deployment/DaemonSet/StatefulSet (not Service/PVC)
- `dependsOn: apps-base` for propagation policies (namespaces must exist first)

### Flux
- One Kustomization per app; apps depend on `apps-base` + `karmada-propagation-policies`
- Edge infrastructure: two Kustomizations per cluster (helm + raw)
- `retryInterval: 30s` on edge raw for cert-manager webhook timing

### Per-cluster DNS
- Central services: `*.kubew.dev`
- Edge apps: `*.{subdomain}.kubew.dev` (e.g., `*.edge1.kubew.dev`)
- Each cluster gets its own Traefik, cert-manager (wildcard cert), ExternalDNS

## Hardware

| Device | Role | RAM | Status |
|--------|------|-----|--------|
| MacBook Pro M3 Max | Development workstation (CLI, SSH, bootstrap) | 32GB | Active |
| Raspberry Pi 5 (pi-central) | Central: K3s + Karmada + Rancher + Zitadel + GitLab + Flux | 16GB + 1TB NVMe | Active |
| Raspberry Pi 5 (pi-edge-1) | Edge: HA + Companion + Node-RED + MQTT + IoT apps | 16GB | Active |

## Project Phases

- [x] Phase 0: Foundation (bootstrap, Pi provisioning, operational tooling)
- [x] Phase 1: Central management node (Karmada + Rancher + Flux + Zitadel + GitLab)
- [x] Phase 2: Edge cluster with full ingress stack (per-cluster DNS, Flux-managed)
- [x] Phase 3: Home Assistant + IoT apps deployed via GitOps with SSO
- [ ] Phase 4: Observability (Prometheus + Grafana with Zitadel SSO)
- [ ] Phase 5: Terraform applied (Cloudflare DNS, Tailscale), cloud expansion
- [ ] Phase 6: Additional edge clusters, advanced scheduling, Matrix/Element
