# Terraform Infrastructure for kube-world
# Cloud-agnostic infrastructure provisioning

This directory contains Terraform modules for managing cloud-agnostic infrastructure.

## Structure

```
infrastructure/
├── README.md           # This file
├── terraform.tf        # Provider configuration
├── variables.tf        # Common variables
├── outputs.tf          # Common outputs
├── modules/
│   ├── dns/           # DNS management (Route53/CloudDNS/Azure DNS)
│   ├── storage/       # Backup storage (S3/GCS/Azure Blob)
│   ├── kubernetes/    # Managed K8s (EKS/GKE/AKS)
│   └── networking/    # VPC/VNet configuration
└── environments/
    ├── dev/           # Development environment
    └── prod/          # Production environment
```

## Usage

### Prerequisites

```bash
# Install Terraform
brew install terraform  # macOS
# or
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt-get update && sudo apt-get install terraform
```

### Initialize

```bash
cd infrastructure/environments/dev
terraform init
```

### Plan

```bash
terraform plan -var-file=terraform.tfvars
```

### Apply

```bash
terraform apply -var-file=terraform.tfvars
```

## Cloud Provider Configuration

This infrastructure is designed to be cloud-agnostic. Set the `cloud_provider` variable to:

- `aws` - Amazon Web Services
- `gcp` - Google Cloud Platform  
- `azure` - Microsoft Azure
- `local` - Local/MinIO (for development)

Each module automatically uses the appropriate provider-specific resources.

## Cost Estimation

Before applying, use:

```bash
terraform plan -out=plan.tfplan
infracost breakdown --path=plan.tfplan
```

See the `cost-evaluation/` directory for advanced cost optimization tools.
