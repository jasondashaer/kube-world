# Cloudflare DNS Module for kube-world
#
# Manages the kubew.dev zone's DNS records on Cloudflare.
# Uses CNAME records pointing to Tailscale MagicDNS names so records
# never need updating when IPs change.
#
# Architecture:
#   *.kubew.dev         CNAME → pi-central.<tailnet>.ts.net  (central services)
#   *.edge1.kubew.dev   CNAME → pi-edge-1.<tailnet>.ts.net   (edge1 apps)
#   *.edge2.kubew.dev   CNAME → pi-edge-2.<tailnet>.ts.net   (edge2 apps)

terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

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
  description = "Map of edge cluster name → configuration"
  type = map(object({
    subdomain          = string
    tailscale_hostname = string
  }))
  default = {}
}

#===============================================================================
# Zone lookup (assumes domain is already registered on Cloudflare)
#===============================================================================
data "cloudflare_zone" "main" {
  name = var.domain
}

#===============================================================================
# Central cluster DNS — two CNAMEs cover all management services
#===============================================================================

# Root domain → central Pi via Tailscale MagicDNS
resource "cloudflare_record" "root" {
  zone_id = data.cloudflare_zone.main.id
  name    = "@"
  content = "${var.central_hostname}.${var.tailnet_dns_suffix}"
  type    = "CNAME"
  ttl     = 60
  proxied = false
  comment = "Root domain → central Pi (Tailscale MagicDNS)"
}

# Wildcard *.kubew.dev → central Pi (catches rancher, auth, gitlab, etc.)
resource "cloudflare_record" "wildcard" {
  zone_id = data.cloudflare_zone.main.id
  name    = "*"
  content = "${var.central_hostname}.${var.tailnet_dns_suffix}"
  type    = "CNAME"
  ttl     = 60
  proxied = false
  comment = "Wildcard → central Pi for management services"
}

#===============================================================================
# Per-edge-cluster wildcard DNS
# DNS wildcards match one label only, so *.kubew.dev does NOT cover
# *.edge1.kubew.dev. Each edge cluster gets its own wildcard CNAME.
#===============================================================================
resource "cloudflare_record" "edge_wildcard" {
  for_each = var.edge_clusters

  zone_id = data.cloudflare_zone.main.id
  name    = "*.${each.value.subdomain}"
  content = "${each.value.tailscale_hostname}.${var.tailnet_dns_suffix}"
  type    = "CNAME"
  ttl     = 60
  proxied = false
  comment = "Edge cluster ${each.key}: *.${each.value.subdomain}.${var.domain}"
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

output "central_cname_target" {
  description = "Central Pi CNAME target"
  value       = "${var.central_hostname}.${var.tailnet_dns_suffix}"
}

output "edge_cname_targets" {
  description = "Edge cluster CNAME targets"
  value = {
    for name, config in var.edge_clusters :
    name => "*.${config.subdomain}.${var.domain} → ${config.tailscale_hostname}.${var.tailnet_dns_suffix}"
  }
}

output "nameservers" {
  description = "Cloudflare nameservers for the zone"
  value       = data.cloudflare_zone.main.name_servers
}
