terraform {
  required_version = ">= 1.6"

  # Bucket comes from -backend-config at init time so the same code works
  # locally and in CI without hardcoding an environment.
  backend "gcs" {
    prefix = "looking-for-songs"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.0, < 8.0"
    }
    # API Gateway resources are only in the beta provider.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0, < 8.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}
