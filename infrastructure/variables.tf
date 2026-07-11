# Variables for kube-world Terraform
#
# Sensitive values are passed via environment variables:
#   TF_VAR_cloudflare_api_token
#   TF_VAR_tailscale_api_key

#===============================================================================
# Cloudflare
#===============================================================================
variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:DNS:Edit permissions"
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "Primary domain name"
  type        = string
  default     = "kubew.dev"
}

variable "tailnet_dns_suffix" {
  description = "Tailscale tailnet DNS suffix (e.g., tailab53c1.ts.net)"
  type        = string
}

variable "central_hostname" {
  description = "Tailscale hostname of the central management node"
  type        = string
  default     = "pi-central"
}

variable "edge_clusters" {
  description = "Edge cluster definitions"
  type = map(object({
    subdomain          = string
    tailscale_hostname = string
  }))
  default = {
    pi-edge-1 = {
      subdomain          = "edge1"
      tailscale_hostname = "pi-edge-1"
    }
  }
}

variable "extra_records" {
  description = "Single-host CNAME records for services on a specific machine or tunnel (see module docs)"
  type = map(object({
    target  = string
    proxied = bool
  }))
  default = {
    # Aletheia dev/beta — public via Cloudflare Tunnel "aletheia-dev" running on Jackson's
    # MacBook alongside dev-up.sh (tunnel config: ~/.cloudflared/config.yml). Revisit once
    # Aletheia gets its own hardware/cluster in its 3b phase — this record moves or is removed.
    aletheia = {
      target  = "f343a4cd-6436-4341-a1b1-ee20364b8423.cfargotunnel.com"
      proxied = true
    }
  }
}

#===============================================================================
# Tailscale
#===============================================================================
variable "tailscale_api_key" {
  description = "Tailscale API key for auth key management"
  type        = string
  sensitive   = true
}

variable "tailnet" {
  description = "Tailscale tailnet name"
  type        = string
}
