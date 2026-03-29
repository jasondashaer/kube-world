# Cloudflare DNS Module for kube-world
#
# Manages the kbw.dev domain zone and DNS records on Cloudflare.
# Domain registration is done via Cloudflare dashboard (not Terraform).
# This module manages the zone and records after registration.
#
# Split DNS strategy:
#   - Cloudflare manages public kbw.dev zone
#   - Tailscale MagicDNS resolves *.kbw.dev to Tailscale IPs within tailnet
#   - Cloudflare Tunnels expose specific services publicly when needed

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:Edit permissions"
  type        = string
  sensitive   = true
}

variable "domain" {
  description = "Primary domain name"
  type        = string
  default     = "kbw.dev"
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID"
  type        = string
}

variable "tailscale_pi_ip" {
  description = "Tailscale IP of the central Pi node"
  type        = string
  default     = "100.124.136.58"
}

variable "tailscale_mac_ip" {
  description = "Tailscale IP of the Mac workstation"
  type        = string
  default     = "100.92.128.19"
}

variable "services" {
  description = "Map of service subdomains to target Tailscale IPs"
  type = map(object({
    target      = string
    description = string
    proxied     = bool
  }))
  default = {
    gitlab = {
      target      = "pi"
      description = "GitLab CE (self-hosted on central Pi)"
      proxied     = false
    }
    rancher = {
      target      = "pi"
      description = "Rancher management UI"
      proxied     = false
    }
    auth = {
      target      = "pi"
      description = "Zitadel identity provider"
      proxied     = false
    }
    ntfy = {
      target      = "pi"
      description = "ntfy push notification server"
      proxied     = false
    }
    ha = {
      target      = "pi"
      description = "Home Assistant (future, on edge Pi)"
      proxied     = false
    }
  }
}

#===============================================================================
# Zone (assumes domain is already registered on Cloudflare)
#===============================================================================
data "cloudflare_zone" "main" {
  name = var.domain
}

#===============================================================================
# DNS Records — Tailscale split DNS
# These records resolve to Tailscale IPs, only accessible from the tailnet.
# For public access, use Cloudflare Tunnels instead of A records.
#===============================================================================
locals {
  target_ips = {
    pi  = var.tailscale_pi_ip
    mac = var.tailscale_mac_ip
  }
}

resource "cloudflare_record" "services" {
  for_each = var.services

  zone_id = data.cloudflare_zone.main.id
  name    = each.key
  content = local.target_ips[each.value.target]
  type    = "A"
  ttl     = 300
  proxied = each.value.proxied
  comment = each.value.description
}

# Wildcard record for any undefined subdomains → central Pi
resource "cloudflare_record" "wildcard" {
  zone_id = data.cloudflare_zone.main.id
  name    = "*"
  content = var.tailscale_pi_ip
  type    = "A"
  ttl     = 300
  proxied = false
  comment = "Wildcard fallback to central Pi via Tailscale"
}

# Root domain → central Pi
resource "cloudflare_record" "root" {
  zone_id = data.cloudflare_zone.main.id
  name    = "@"
  content = var.tailscale_pi_ip
  type    = "A"
  ttl     = 300
  proxied = false
  comment = "Root domain to central Pi via Tailscale"
}

#===============================================================================
# Outputs
#===============================================================================
output "zone_id" {
  description = "Cloudflare zone ID"
  value       = data.cloudflare_zone.main.id
}

output "domain" {
  description = "The managed domain"
  value       = var.domain
}

output "service_records" {
  description = "Created DNS records"
  value = {
    for name, record in cloudflare_record.services :
    name => "${name}.${var.domain} → ${record.content}"
  }
}

output "nameservers" {
  description = "Cloudflare nameservers for the zone"
  value       = data.cloudflare_zone.main.name_servers
}
