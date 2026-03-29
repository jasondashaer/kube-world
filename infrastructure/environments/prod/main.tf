# Production environment — kube-world
#
# Manages Cloudflare DNS for kubew.dev domain.
#
# Usage:
#   export CLOUDFLARE_API_TOKEN="your-token"
#   cd infrastructure/environments/prod
#   terraform init
#   terraform plan
#   terraform apply

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

# Cloudflare provider reads CLOUDFLARE_API_TOKEN from environment
provider "cloudflare" {}

module "dns" {
  source = "../../modules/cloudflare-dns"

  cloudflare_api_token  = var.cloudflare_api_token
  cloudflare_account_id = var.cloudflare_account_id
  domain                = "kubew.dev"
  tailscale_pi_ip       = "100.124.136.58"
  tailscale_mac_ip      = "100.92.128.19"
}

output "dns_records" {
  value = module.dns.service_records
}

output "nameservers" {
  value = module.dns.nameservers
}
