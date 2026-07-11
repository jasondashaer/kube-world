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

variable "extra_records" {
  description = <<-EOT
    Single-host CNAME records for services that don't fit the central/edge-cluster
    model (e.g. a project dev instance on a specific machine, or a Cloudflare Tunnel).
    Overrides the wildcard for that exact name — DNS exact match beats wildcard match.
    Key = subdomain label (e.g. "aletheia"); target = full CNAME target FQDN
    (a tailscale MagicDNS name, a <tunnel-id>.cfargotunnel.com, etc.);
    proxied = true routes through Cloudflare's edge (required for tunnel targets).
  EOT
  type = map(object({
    target  = string
    proxied = bool
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
# Single-host records — exact-match, so they take precedence over the wildcard
# for services that live on one specific machine rather than a whole cluster.
#===============================================================================
resource "cloudflare_record" "extra" {
  for_each = var.extra_records

  zone_id = data.cloudflare_zone.main.id
  name    = each.key
  content = each.value.target
  type    = "CNAME"
  # Cloudflare requires ttl=1 ("automatic") on proxied records.
  ttl     = each.value.proxied ? 1 : 60
  proxied = each.value.proxied
  comment = "Single-host: ${each.key}.${var.domain} → ${each.value.target}"
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

output "extra_cname_targets" {
  description = "Single-host CNAME targets"
  value = {
    for name, rec in var.extra_records :
    name => "${name}.${var.domain} → ${rec.target}${rec.proxied ? " (proxied)" : ""}"
  }
}
