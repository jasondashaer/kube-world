# Variables for prod environment
# Sensitive values provided via environment variables or .tfvars (gitignored)

variable "cloudflare_api_token" {
  description = "Cloudflare API token (set via CLOUDFLARE_API_TOKEN env var or terraform.tfvars)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (set via TF_VAR_cloudflare_account_id env var or terraform.tfvars)"
  type        = string
}
