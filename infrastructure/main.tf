# kube-world Infrastructure — Module Composition
#
# Wires together Cloudflare DNS and Tailscale modules.
# Run: cd infrastructure && terraform init && terraform apply

module "dns" {
  source = "./modules/cloudflare-dns"

  cloudflare_api_token = var.cloudflare_api_token
  domain               = var.domain
  tailnet_dns_suffix   = var.tailnet_dns_suffix
  central_hostname     = var.central_hostname
  edge_clusters        = var.edge_clusters
  extra_records        = var.extra_records
}

module "tailscale" {
  source = "./modules/tailscale"

  tailscale_api_key = var.tailscale_api_key
  tailnet           = var.tailnet
}

#===============================================================================
# Outputs
#===============================================================================
output "dns_zone_id" {
  value = module.dns.zone_id
}

output "dns_central_target" {
  value = module.dns.central_cname_target
}

output "dns_edge_targets" {
  value = module.dns.edge_cname_targets
}

output "dns_extra_targets" {
  value = module.dns.extra_cname_targets
}

output "tailscale_auth_key" {
  value     = module.tailscale.auth_key
  sensitive = true
}
