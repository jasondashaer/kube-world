# Cost Evaluation Framework for kube-world
# Future: Automated cost optimization for cloud resource selection

This directory contains the cost evaluation framework for intelligent deployment decisions.

## Overview

The cost evaluation system helps make data-driven decisions about:
- **Cloud Provider Selection**: AWS vs GCP vs Azure for specific workloads
- **Region Selection**: Based on latency, cost, and compliance
- **Resource Sizing**: Right-sizing VMs, storage, and networking
- **BCDR Planning**: Cost-effective backup and disaster recovery
- **Hybrid Decisions**: When to use edge (Pi) vs cloud

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Cost Evaluation System                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │   Pricing    │  │   Metrics    │  │   Workload           │   │
│  │   APIs       │  │   Collector  │  │   Analyzer           │   │
│  │  (AWS/GCP/   │  │  (Prometheus │  │  (Resource needs,    │   │
│  │   Azure)     │  │   OpenCost)  │  │   latency reqs)      │   │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘   │
│         │                 │                      │               │
│         └─────────────────┼──────────────────────┘               │
│                           │                                      │
│                    ┌──────▼───────┐                              │
│                    │   Decision   │                              │
│                    │   Engine     │                              │
│                    │  (Scoring,   │                              │
│                    │   Ranking)   │                              │
│                    └──────┬───────┘                              │
│                           │                                      │
│                    ┌──────▼───────┐                              │
│                    │ Recommender  │                              │
│                    │ (Terraform   │                              │
│                    │  configs)    │                              │
│                    └──────────────┘                              │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Components

### 1. Pricing Collector (`pricing/`)
Fetches real-time pricing from cloud providers:
- AWS Price List API
- GCP Cloud Billing Catalog API
- Azure Retail Prices API

### 2. Metrics Integration (`metrics/`)
Collects actual usage metrics:
- OpenCost for Kubernetes cost allocation
- Prometheus for resource utilization
- Cloud provider billing APIs

### 3. Decision Engine (`engine/`)
Scores options based on:
- Cost (monthly estimate)
- Performance (latency, throughput)
- Reliability (SLA, BCDR)
- Compliance (data residency)
- Integrability (API compatibility)

### 4. Recommender (`recommender/`)
Generates:
- Terraform configurations for optimal setup
- Alerts when better options become available
- Migration recommendations

## Usage (Future)

```bash
# Evaluate deployment options for a workload
./cost-eval evaluate --workload home-assistant --requirements requirements.yaml

# Compare current vs optimal
./cost-eval compare --current terraform.tfstate

# Generate optimized Terraform
./cost-eval generate --output infrastructure/environments/prod/
```

## Integration with kube-world

1. **Pre-deployment**: Evaluate options before `terraform apply`
2. **Continuous**: Monitor costs and recommend changes
3. **GitOps**: Auto-create PRs for cost optimizations

## Roadmap

- [x] Framework structure
- [ ] AWS pricing collector
- [ ] GCP pricing collector
- [ ] Azure pricing collector
- [ ] OpenCost integration
- [ ] Decision engine core
- [ ] Terraform generator
- [ ] Kubernetes Operator (CRD-based)
- [ ] GitHub Actions integration

## External Tools

Consider integrating with:
- [Infracost](https://www.infracost.io/) - Terraform cost estimation
- [OpenCost](https://www.opencost.io/) - Kubernetes cost monitoring
- [Kubecost](https://www.kubecost.com/) - Alternative cost monitoring
- [Komiser](https://www.komiser.io/) - Cloud cost management
