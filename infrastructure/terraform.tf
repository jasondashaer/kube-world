# Terraform Configuration for kube-world
#
# Manages external resources that live OUTSIDE Kubernetes:
#   - Cloudflare: DNS zone, wildcard CNAMEs per cluster
#   - Tailscale: Auth keys for new node provisioning
#   - Future: Cloud provider infra (VPCs, EKS/GKE clusters)
#
# Everything INSIDE Kubernetes is managed by Flux (not Terraform).
#
# State backend: GitLab-managed Terraform state
#   terraform init \
#     -backend-config="address=http://gitlab.kubew.dev/api/v4/projects/1/terraform/state/kube-world" \
#     -backend-config="lock_address=http://gitlab.kubew.dev/api/v4/projects/1/terraform/state/kube-world/lock" \
#     -backend-config="unlock_address=http://gitlab.kubew.dev/api/v4/projects/1/terraform/state/kube-world/lock" \
#     -backend-config="username=root" \
#     -backend-config="password=$GITLAB_TOKEN"

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17"
    }
  }

  # GitLab-managed state — configure via -backend-config at init time
  backend "http" {}
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailnet
}
