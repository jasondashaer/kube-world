# Cloud-Agnostic Backup Storage Module
# Creates storage for Velero backups across AWS/GCP/Azure/MinIO

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

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "retention_days" {
  type    = number
  default = 30
}

# Random suffix for unique naming
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  bucket_name = "${var.project_name}-backups-${var.environment}-${random_id.bucket_suffix.hex}"
}

#===============================================================================
# AWS S3 Bucket
#===============================================================================
resource "aws_s3_bucket" "velero" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = local.bucket_name

  tags = {
    Name        = local.bucket_name
    Purpose     = "velero-backups"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_versioning" "velero" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id
  
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "velero" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    expiration {
      days = var.retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "velero" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "velero" {
  count  = var.cloud_provider == "aws" ? 1 : 0
  bucket = aws_s3_bucket.velero[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM role for Velero
resource "aws_iam_role" "velero" {
  count = var.cloud_provider == "aws" ? 1 : 0
  name  = "${var.project_name}-velero-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRoleWithWebIdentity"
        Effect = "Allow"
        Principal = {
          Federated = "arn:aws:iam::*:oidc-provider/*"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "velero" {
  count = var.cloud_provider == "aws" ? 1 : 0
  name  = "velero-backup-policy"
  role  = aws_iam_role.velero[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts"
        ]
        Resource = "${aws_s3_bucket.velero[0].arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.velero[0].arn
      }
    ]
  })
}

#===============================================================================
# GCP Cloud Storage Bucket
#===============================================================================
resource "google_storage_bucket" "velero" {
  count         = var.cloud_provider == "gcp" ? 1 : 0
  name          = local.bucket_name
  location      = "US"
  force_destroy = false

  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = var.retention_days
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    purpose     = "velero-backups"
    environment = var.environment
  }
}

# Service account for Velero
resource "google_service_account" "velero" {
  count        = var.cloud_provider == "gcp" ? 1 : 0
  account_id   = "${var.project_name}-velero"
  display_name = "Velero Backup Service Account"
}

resource "google_storage_bucket_iam_member" "velero" {
  count  = var.cloud_provider == "gcp" ? 1 : 0
  bucket = google_storage_bucket.velero[0].name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.velero[0].email}"
}

#===============================================================================
# Azure Blob Storage
#===============================================================================
resource "azurerm_storage_account" "velero" {
  count                    = var.cloud_provider == "azure" ? 1 : 0
  name                     = replace(local.bucket_name, "-", "")
  resource_group_name      = var.azure_resource_group
  location                 = var.azure_location
  account_tier             = "Standard"
  account_replication_type = "GRS"
  
  blob_properties {
    versioning_enabled = true
    
    delete_retention_policy {
      days = 7
    }
  }

  tags = {
    purpose     = "velero-backups"
    environment = var.environment
  }
}

resource "azurerm_storage_container" "velero" {
  count                 = var.cloud_provider == "azure" ? 1 : 0
  name                  = "velero"
  storage_account_name  = azurerm_storage_account.velero[0].name
  container_access_type = "private"
}

variable "azure_resource_group" {
  type    = string
  default = ""
}

variable "azure_location" {
  type    = string
  default = "eastus"
}

#===============================================================================
# Outputs
#===============================================================================
output "bucket_name" {
  description = "Name of the backup storage bucket"
  value = coalesce(
    var.cloud_provider == "aws" ? try(aws_s3_bucket.velero[0].id, "") : "",
    var.cloud_provider == "gcp" ? try(google_storage_bucket.velero[0].name, "") : "",
    var.cloud_provider == "azure" ? try(azurerm_storage_container.velero[0].name, "") : "",
    "not-created"
  )
}

output "bucket_region" {
  description = "Region of the backup storage"
  value = coalesce(
    var.cloud_provider == "aws" ? try(aws_s3_bucket.velero[0].region, "") : "",
    var.cloud_provider == "gcp" ? try(google_storage_bucket.velero[0].location, "") : "",
    var.cloud_provider == "azure" ? try(azurerm_storage_account.velero[0].location, "") : "",
    "local"
  )
}

output "velero_config" {
  description = "Configuration for Velero Helm chart"
  value = {
    provider = var.cloud_provider
    bucket   = local.bucket_name
    config = var.cloud_provider == "aws" ? {
      region = try(aws_s3_bucket.velero[0].region, "us-east-1")
    } : var.cloud_provider == "gcp" ? {
      project = try(google_storage_bucket.velero[0].project, "")
    } : var.cloud_provider == "azure" ? {
      resourceGroup  = var.azure_resource_group
      storageAccount = try(azurerm_storage_account.velero[0].name, "")
    } : {}
  }
}
