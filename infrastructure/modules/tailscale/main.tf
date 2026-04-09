# Tailscale Module for kube-world
#
# Manages Tailscale auth keys for new node provisioning.
# Auth keys are reusable, tagged, and time-limited so new Pis can
# join the tailnet during cloud-init/Ansible without manual approval.

terraform {
  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.17"
    }
  }
}

variable "tailscale_api_key" {
  description = "Tailscale API key (not OAuth client — API key from admin console)"
  type        = string
  sensitive   = true
}

variable "tailnet" {
  description = "Tailscale tailnet name (e.g., user@github)"
  type        = string
}

variable "auth_key_tags" {
  description = "Tags to apply to devices joining with this key"
  type        = list(string)
  default     = ["tag:edge"]
}

variable "auth_key_expiry" {
  description = "Auth key expiry in seconds (default: 1 hour)"
  type        = number
  default     = 3600
}

variable "auth_key_reusable" {
  description = "Whether the auth key can be used by multiple devices"
  type        = bool
  default     = true
}

#===============================================================================
# Bootstrap auth key for new node provisioning
#===============================================================================
resource "tailscale_tailnet_key" "bootstrap" {
  reusable      = var.auth_key_reusable
  ephemeral     = false
  preauthorized = true
  expiry        = var.auth_key_expiry
  tags          = var.auth_key_tags
  description   = "kube-world bootstrap key (Terraform-managed)"
}

#===============================================================================
# Outputs
#===============================================================================
output "auth_key" {
  description = "Tailscale auth key for node provisioning"
  value       = tailscale_tailnet_key.bootstrap.key
  sensitive   = true
}

output "auth_key_id" {
  description = "Auth key ID"
  value       = tailscale_tailnet_key.bootstrap.id
}
