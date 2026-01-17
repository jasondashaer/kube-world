# Cloud-Agnostic DNS Module
# Manages DNS zones and records across AWS/GCP/Azure

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
  }
}

variable "cloud_provider" {
  type = string
}

variable "domain_name" {
  type = string
}

variable "create_zone" {
  type    = bool
  default = true
}

variable "environment" {
  type = string
}

variable "records" {
  description = "DNS records to create"
  type = list(object({
    name    = string
    type    = string
    ttl     = number
    records = list(string)
  }))
  default = []
}

#===============================================================================
# AWS Route 53
#===============================================================================
resource "aws_route53_zone" "main" {
  count = var.cloud_provider == "aws" && var.create_zone ? 1 : 0
  name  = var.domain_name

  tags = {
    Environment = var.environment
  }
}

resource "aws_route53_record" "records" {
  for_each = var.cloud_provider == "aws" ? {
    for idx, record in var.records : "${record.name}-${record.type}" => record
  } : {}

  zone_id = var.create_zone ? aws_route53_zone.main[0].zone_id : data.aws_route53_zone.existing[0].zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = each.value.ttl
  records = each.value.records
}

data "aws_route53_zone" "existing" {
  count = var.cloud_provider == "aws" && !var.create_zone ? 1 : 0
  name  = var.domain_name
}

#===============================================================================
# GCP Cloud DNS
#===============================================================================
resource "google_dns_managed_zone" "main" {
  count       = var.cloud_provider == "gcp" && var.create_zone ? 1 : 0
  name        = replace(var.domain_name, ".", "-")
  dns_name    = "${var.domain_name}."
  description = "DNS zone for ${var.domain_name}"

  labels = {
    environment = var.environment
  }
}

resource "google_dns_record_set" "records" {
  for_each = var.cloud_provider == "gcp" ? {
    for idx, record in var.records : "${record.name}-${record.type}" => record
  } : {}

  name         = "${each.value.name}.${var.domain_name}."
  type         = each.value.type
  ttl          = each.value.ttl
  managed_zone = var.create_zone ? google_dns_managed_zone.main[0].name : data.google_dns_managed_zone.existing[0].name
  rrdatas      = each.value.records
}

data "google_dns_managed_zone" "existing" {
  count = var.cloud_provider == "gcp" && !var.create_zone ? 1 : 0
  name  = replace(var.domain_name, ".", "-")
}

#===============================================================================
# Azure DNS
#===============================================================================
resource "azurerm_dns_zone" "main" {
  count               = var.cloud_provider == "azure" && var.create_zone ? 1 : 0
  name                = var.domain_name
  resource_group_name = var.azure_resource_group

  tags = {
    environment = var.environment
  }
}

resource "azurerm_dns_a_record" "a_records" {
  for_each = var.cloud_provider == "azure" ? {
    for idx, record in var.records : "${record.name}-${record.type}" => record
    if record.type == "A"
  } : {}

  name                = each.value.name
  zone_name           = var.create_zone ? azurerm_dns_zone.main[0].name : var.domain_name
  resource_group_name = var.azure_resource_group
  ttl                 = each.value.ttl
  records             = each.value.records
}

resource "azurerm_dns_cname_record" "cname_records" {
  for_each = var.cloud_provider == "azure" ? {
    for idx, record in var.records : "${record.name}-${record.type}" => record
    if record.type == "CNAME"
  } : {}

  name                = each.value.name
  zone_name           = var.create_zone ? azurerm_dns_zone.main[0].name : var.domain_name
  resource_group_name = var.azure_resource_group
  ttl                 = each.value.ttl
  record              = each.value.records[0]
}

variable "azure_resource_group" {
  type    = string
  default = ""
}

#===============================================================================
# Outputs
#===============================================================================
output "zone_id" {
  description = "DNS zone identifier"
  value = coalesce(
    var.cloud_provider == "aws" && var.create_zone ? try(aws_route53_zone.main[0].zone_id, "") : "",
    var.cloud_provider == "gcp" && var.create_zone ? try(google_dns_managed_zone.main[0].id, "") : "",
    var.cloud_provider == "azure" && var.create_zone ? try(azurerm_dns_zone.main[0].id, "") : "",
    "not-created"
  )
}

output "name_servers" {
  description = "Name servers for the DNS zone"
  value = coalesce(
    var.cloud_provider == "aws" && var.create_zone ? try(aws_route53_zone.main[0].name_servers, []) : [],
    var.cloud_provider == "gcp" && var.create_zone ? try(google_dns_managed_zone.main[0].name_servers, []) : [],
    var.cloud_provider == "azure" && var.create_zone ? try(azurerm_dns_zone.main[0].name_servers, []) : [],
    []
  )
}

output "domain" {
  description = "The domain name"
  value       = var.domain_name
}
