# Terraform Configuration for kube-world
# Supports AWS, GCP, Azure, and local (MinIO) backends

terraform {
  required_version = ">= 1.6.0"
  
  required_providers {
    # AWS Provider
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    
    # Google Cloud Provider
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    
    # Azure Provider
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }
    
    # Kubernetes Provider (for in-cluster resources)
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
    
    # Helm Provider
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    
    # Random (for unique naming)
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
  
  # Backend configuration - override in environments
  # backend "s3" {}      # For AWS
  # backend "gcs" {}     # For GCP
  # backend "azurerm" {} # For Azure
}

# Configure providers based on selected cloud
provider "aws" {
  region = var.cloud_provider == "aws" ? var.aws_region : "us-east-1"
  
  default_tags {
    tags = {
      Project     = "kube-world"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
  
  # Skip if not using AWS
  skip_credentials_validation = var.cloud_provider != "aws"
  skip_metadata_api_check     = var.cloud_provider != "aws"
  skip_requesting_account_id  = var.cloud_provider != "aws"
}

provider "google" {
  project = var.cloud_provider == "gcp" ? var.gcp_project : null
  region  = var.cloud_provider == "gcp" ? var.gcp_region : "us-central1"
}

provider "azurerm" {
  features {}
  skip_provider_registration = var.cloud_provider != "azure"
}

provider "kubernetes" {
  # Configuration will be provided by cluster setup
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}
