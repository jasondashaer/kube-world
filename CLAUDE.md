# CLAUDE.md - AI Assistant Guide for kube-world

## Project Overview

kube-world is an ephemeral, multi-cluster Kubernetes orchestration framework. It deploys independent K3s clusters across Raspberry Pi edge devices, macOS development environments, and (future) cloud providers, using Karmada for multi-cluster scheduling, Flux for GitOps, and Rancher for management UI.

**Repository**: `https://github.com/jasondashaer/kube-world.git`
**License**: MIT | **Branch**: `main`

## Architecture (Karmada + Flux + Rancher)

```
GitHub (source of truth) --> Flux (GitOps) --> Karmada API (scheduling) --> Target Clusters
                                                                              |
                                                    Rancher (UI/monitoring) --+
```

- **Each Pi is an independent K3s cluster** (not nodes in one cluster) for failure isolation
- **Karmada** schedules workloads across clusters based on labels, resources, and affinity
- **Flux** watches Git and applies manifests to the Karmada API server
- **Rancher** provides management UI, RBAC, and monitoring dashboards
- **Tailscale** provides mesh VPN between all clusters

### Migration Status (from Fleet to Karmada + Flux)
- `gitops/fleet.yaml` and `apps/*/fleet.yaml` are **deprecated** reference files
- New architecture lives in `karmada/` and `flux/` directories
- Fleet-specific logic in `bootstrap.sh` is being replaced

### Future: Self-hosted GitLab
Currently using GitHub. Plan to self-host GitLab on a dedicated Pi 5 (16GB) central management node. GitLab needs ~2.5-4GB RAM (tuned). Design all Git interactions to be portable between GitHub and GitLab.

## Repository Structure

```
kube-world/
├── bootstrap.sh              # Main entry point (~750 lines)
├── config.yaml               # Central configuration (single source of truth)
├── .sops.yaml                # SOPS encryption rules (age-based)
├── .yamllint.yml             # YAML lint: 2-space indent, 120-char max
├── .github/workflows/ci.yml  # CI: lint, validate, scan, test (7 jobs)
│
├── karmada/                           # Multi-cluster scheduling
│   ├── install-karmada.sh             # Control plane installation
│   ├── propagation-policies/          # Where workloads go
│   │   ├── home-assistant.yaml        # HA -> Pi IoT clusters
│   │   ├── base.yaml                 # Namespaces/policies -> all clusters
│   │   └── monitoring.yaml           # Monitoring -> all clusters
│   ├── override-policies/            # Cluster-specific overrides
│   │   └── pi-overrides.yaml         # Resource limits for Pi hardware
│   └── cluster-registration/
│       └── register-pi.sh            # Register Pi cluster to Karmada
│
├── flux/                              # GitOps (replaces gitops/fleet.yaml)
│   ├── sources/
│   │   └── git-repository.yaml       # Points to this repo
│   └── kustomizations/
│       ├── karmada-policies.yaml      # Sync Karmada policies
│       ├── apps.yaml                  # Sync app manifests
│       └── policies.yaml             # Sync Kyverno/scheduling
│
├── apps/                              # Application manifests
│   ├── base/namespaces.yaml          # Shared namespaces + quotas
│   ├── home-assistant/               # HA deployment + USB rules
│   └── velero/                       # Backup configuration
│
├── clusters/                          # Cluster definitions
│   ├── mac-local.yaml                # KIND (3-node, ports on 0.0.0.0)
│   └── pi-cluster.yaml              # K3s for Raspberry Pi
│
├── policies/                          # Kyverno + scheduling priorities
│   ├── kyverno-policies.yaml         # 5 cluster policies
│   └── scheduling-priorities.yaml    # PriorityClasses
│
├── rancher/                           # Rancher management
│   ├── install-rancher.sh            # Install with LAN auto-detect
│   ├── import-cluster.sh             # Import cluster helper
│   └── test-connectivity.sh          # Network diagnostics
│
├── pi-setup/                          # Pi provisioning (architecture-agnostic)
│   ├── ansible/playbook.yml          # K3s install (~462 lines)
│   ├── ansible/ansible.cfg           # SSH tuned for WiFi
│   ├── cloud-init/user-data.yaml     # Zero-touch Pi config
│   ├── pi-prep.sh                    # Headless Pi setup (~1149 lines)
│   ├── join-cluster.sh               # Import Pi to Rancher
│   └── scripts/wifi-stability.sh     # WiFi hardening
│
├── scripts/                           # Operational tooling
│   ├── health-check.sh               # Full infra diagnostics
│   └── recover.sh                    # Automated failure recovery
│
├── infrastructure/                    # Terraform (AWS/GCP/Azure)
├── inventory/hardware.yaml            # Hardware registry
├── secrets/                           # SOPS-encrypted secrets
├── cost-evaluation/                   # Cost optimization framework
├── docs/architecture.md               # System design diagrams
├── docs/troubleshooting.md            # Debug guide
│
└── gitops/fleet.yaml                  # DEPRECATED: Fleet config (reference only)
```

## Key Technologies

| Technology | Version | Purpose |
|-----------|---------|---------|
| K3s | v1.29.0+k3s1 | Lightweight Kubernetes for Pi/edge and central node |
| KIND | latest | Local dev clusters on Mac (Docker-based) |
| Karmada | 1.12.0 | Multi-cluster scheduling and workload propagation |
| Flux | 2.4.0 | GitOps - watches Git, applies to Karmada API |
| Rancher | 2.13.1 | Management UI, RBAC, monitoring |
| Helm | 3.14.0 | Kubernetes package manager |
| Ansible | latest | Pi provisioning |
| Terraform | 1.6.0+ | Cloud infrastructure (AWS/GCP/Azure) |
| SOPS + age | latest | Secrets encryption |
| Kyverno | latest | Policy enforcement |
| Tailscale | latest | Mesh VPN between clusters |
| cert-manager | v1.14.0 | TLS certificates |

## Build, Test, and Lint Commands

### Bootstrap (full cluster setup)
```bash
./bootstrap.sh --platform mac --mode dev --verbose   # Mac KIND dev
./bootstrap.sh --platform pi --mode dev --verbose     # Raspberry Pi
./bootstrap.sh --dry-run --platform mac               # Preview only
./bootstrap.sh --cleanup && ./bootstrap.sh            # Clean rebuild
```

### Karmada
```bash
./karmada/install-karmada.sh                          # Install control plane
./karmada/install-karmada.sh --dry-run                # Preview
./karmada/cluster-registration/register-pi.sh --pi-ip 192.168.x.x  # Register Pi
karmadactl get clusters --kubeconfig=~/.karmada/karmada-apiserver.config
```

### Flux
```bash
flux bootstrap github --owner=jasondashaer --repository=kube-world --branch=main --path=flux/bootstrap --personal
flux get sources git                                  # Check Git source
flux get kustomizations                               # Check sync status
flux reconcile kustomization apps-home-assistant      # Force sync
```

### Validation and Linting
```bash
yamllint -c .yamllint.yml .                          # YAML lint
shellcheck bootstrap.sh rancher/install-rancher.sh karmada/install-karmada.sh
find apps/ -name '*.yaml' -type f | xargs kubeconform -summary -strict -ignore-missing-schemas
ansible-lint pi-setup/ansible/playbook.yml
trivy config .                                        # Security scan
```

### Ansible (Pi provisioning)
```bash
ansible-playbook -i pi-setup/ansible/inventory.ini pi-setup/ansible/playbook.yml
```

### Operational
```bash
./scripts/health-check.sh                # Full infrastructure check
./scripts/health-check.sh --mac-only     # Mac cluster only
./scripts/health-check.sh --pi-only      # Pi cluster only
./scripts/health-check.sh --network      # Cross-cluster networking
./scripts/recover.sh rancher             # Restart Rancher
./scripts/recover.sh pi-k3s             # Restart K3s on Pi
```

## CI Pipeline (.github/workflows/ci.yml)

Triggered on push/PR to `main`. Jobs:
1. **Lint**: yamllint + ShellCheck (severity: error)
2. **Validate K8s**: kubeconform with Kyverno CRD schemas
3. **Ansible Lint**: production profile
4. **Security Scan**: Trivy (HIGH/CRITICAL) + SARIF upload
5. **Secrets Scan**: TruffleHog + custom grep for keys/passwords
6. **Test Bootstrap (macOS)**: dry-run + help text
7. **Test Bootstrap (Linux)**: Pi platform simulation + bash syntax validation

## Code Conventions

### Shell Scripts
- `set -euo pipefail` and `IFS=$'\n\t'`
- Logging: `log()` green, `warn()` yellow, `error()` red, `debug()` blue/verbose-only
- Function naming: `snake_case`
- Version vars: `VAR="${VAR:-default}"` (env override with fallback)
- Guard direct execution: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi`

### YAML
- 2-space indent, max 120 chars, truthy: `true`/`false`/`yes`/`no`
- Document start (`---`) not required

### Kubernetes Manifests
- Required label: `app.kubernetes.io/name`
- Infrastructure label: `app.kubernetes.io/part-of: kube-world`
- Resource requests and limits on all containers
- Trusted registries only: `ghcr.io`, `docker.io/library`, `docker.io/rancher`, `registry.k8s.io`

### Node Labels
```yaml
node.kubernetes.io/role: master | worker
topology.kubernetes.io/zone: edge | local | cloud
workload-type: iot | development | general
hardware: raspberry-pi-5 | raspberry-pi | amd64
```

### Karmada Conventions
- **PropagationPolicy**: namespace-scoped, for app-specific placement
- **ClusterPropagationPolicy**: cluster-scoped, for infrastructure (namespaces, policies)
- **OverridePolicy**: cluster-specific resource adjustments (e.g., Pi resource limits)
- Target clusters by labels, not names (allows adding clusters without policy changes)

### Flux Conventions
- One `Kustomization` per logical group (apps-base, apps-home-assistant, policies)
- All Kustomizations point to Karmada API via `kubeConfig.secretRef`
- Use `dependsOn` for ordering (policies before apps)
- `prune: true` for drift correction

### Secrets
- SOPS + age encryption. Public key in `.sops.yaml`
- `config.yaml` fields marked `[SOPS]` must be encrypted before commit
- Private keys (`age.key`, `key.txt`) are gitignored

### Ansible
- Remote user: `admin`, sudo without password
- SSH tuned for WiFi: ControlMaster, ServerAliveInterval=15s, 5 retries
- Package installs batched, long tasks use async with timeouts
- Each play re-establishes connection for WiFi reliability

## Common Patterns

### Adding a new application
1. Create `apps/<app-name>/deployment.yaml` with required labels and limits
2. Create `karmada/propagation-policies/<app-name>.yaml` with placement rules
3. Add Flux kustomization in `flux/kustomizations/apps.yaml`
4. Add namespace to `apps/base/namespaces.yaml` if needed
5. Optionally add `karmada/override-policies/` for cluster-specific overrides

### Registering a new cluster
1. Install K3s (via Ansible or manually)
2. Install Tailscale for mesh connectivity
3. Register with Karmada: `karmadactl join <name> --cluster-kubeconfig=<path>`
4. Apply cluster labels for scheduling
5. Register with Rancher: `./pi-setup/join-cluster.sh`

### Deprecated patterns (from Fleet era)
- `apps/*/fleet.yaml` bundle configs -- no longer used
- `gitops/fleet.yaml` GitRepo definitions -- replaced by `flux/`
- Fleet CRD wait logic in `bootstrap.sh` -- being replaced

## Files to Avoid Modifying Without Understanding
- `.sops.yaml` -- breaking this breaks all secrets
- `bootstrap.sh` main() flow -- execution order is critical
- `rancher/install-rancher.sh` -- sourced by bootstrap.sh, `main()` called programmatically
- `pi-setup/ansible/ansible.cfg` SSH settings -- tuned for WiFi reliability
- `karmada/propagation-policies/` -- incorrect policies can send workloads to wrong clusters

## Debugging

### Karmada scheduling
```bash
karmadactl get clusters                              # Cluster status
karmadactl get rb                                    # Resource bindings (scheduling decisions)
kubectl --kubeconfig=~/.karmada/karmada-apiserver.config get propagationpolicies -A
kubectl --kubeconfig=~/.karmada/karmada-apiserver.config get work -A  # Work objects
```

### Flux sync
```bash
flux get sources git                                 # Git connectivity
flux get kustomizations                              # Sync status
flux logs --level=error                              # Error logs
```

### Rancher
```bash
kubectl -n cattle-system get pods
kubectl -n cattle-system port-forward svc/rancher 8443:443
```

### Pi connectivity
```bash
./rancher/test-connectivity.sh <rancher-host>        # Full diagnostics
./scripts/health-check.sh --network                  # Cross-cluster checks
```

Full troubleshooting guide: `docs/troubleshooting.md`

## Hardware

| Device | Role | RAM | Status |
|--------|------|-----|--------|
| MacBook Pro M3 Max | Development only | 32GB | Active |
| Raspberry Pi 5 | Edge cluster (Home Assistant + IoT) | 16GB + 1TB NVMe | Active |
| Raspberry Pi 5 (TBD) | Central management node | 16GB (planned) | Planned |

## Project Phases

- [x] Phase 0: Foundation (bootstrap, Pi provisioning, operational tooling)
- [ ] Phase 1: Control plane on Mac KIND (Karmada + Rancher + Flux)
- [ ] Phase 2: Pi edge cluster registered to Karmada + Rancher
- [ ] Phase 3: Home Assistant deployed via Flux -> Karmada -> Pi
- [ ] Phase 4: Observability, GitLab self-hosting, dedicated central Pi
- [ ] Phase 5: Multi-cluster expansion, advanced scheduling
