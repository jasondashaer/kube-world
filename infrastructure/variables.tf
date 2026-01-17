# Common Variables for kube-world Infrastructure
# These are shared across all environments

#===============================================================================
# Cloud Provider Selection
#===============================================================================
variable "cloud_provider" {
  description = "Cloud provider to use: aws, gcp, azure, or local"
  type        = string
  default     = "local"
  
  validation {
    condition     = contains(["aws", "gcp", "azure", "local"], var.cloud_provider)
    error_message = "cloud_provider must be one of: aws, gcp, azure, local"
  }
}

variable "environment" {
  description = "Environment name: dev, staging, prod"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name for resource naming"
  type        = string
  default     = "kube-world"
}

#===============================================================================
# AWS-specific Variables
#===============================================================================
variable "aws_region" {
  description = "AWS region for resources"
  type        = string
  default     = "us-east-1"
}

variable "aws_availability_zones" {
  description = "AWS availability zones"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

#===============================================================================
# GCP-specific Variables
#===============================================================================
variable "gcp_project" {
  description = "GCP project ID"
  type        = string
  default     = ""
}

variable "gcp_region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "gcp_zone" {
  description = "GCP zone for zonal resources"
  type        = string
  default     = "us-central1-a"
}

#===============================================================================
# Azure-specific Variables
#===============================================================================
variable "azure_location" {
  description = "Azure location for resources"
  type        = string
  default     = "eastus"
}

variable "azure_resource_group" {
  description = "Azure resource group name"
  type        = string
  default     = ""
}

#===============================================================================
# Kubernetes Configuration
#===============================================================================
variable "kubeconfig_path" {
  description = "Path to kubeconfig file"
  type        = string
  default     = "~/.kube/config"
}

variable "kubernetes_version" {
  description = "Kubernetes version for managed clusters"
  type        = string
  default     = "1.29"
}

#===============================================================================
# DNS Configuration
#===============================================================================
variable "domain_name" {
  description = "Primary domain name for the project"
  type        = string
  default     = ""
}

variable "create_dns_zone" {
  description = "Whether to create a DNS zone"
  type        = bool
  default     = false
}

#===============================================================================
# Backup Configuration
#===============================================================================
variable "backup_enabled" {
  description = "Enable backup storage creation"
  type        = bool
  default     = true
}

variable "backup_retention_days" {
  description = "Number of days to retain backups"
  type        = number
  default     = 30
}

#===============================================================================
# Networking
#===============================================================================
variable "vpc_cidr" {
  description = "CIDR block for VPC/VNet"
  type        = string
  default     = "10.0.0.0/16"
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

#===============================================================================
# Cost Management
#===============================================================================
variable "cost_center" {
  description = "Cost center for billing allocation"
  type        = string
  default     = "homelab"
}

variable "budget_monthly_usd" {
  description = "Monthly budget in USD (for alerts)"
  type        = number
  default     = 50
}
