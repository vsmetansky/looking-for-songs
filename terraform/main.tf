locals {
  required_services = [
    "run.googleapis.com",
    "artifactregistry.googleapis.com",
    "secretmanager.googleapis.com",
    "apigateway.googleapis.com",
    "servicemanagement.googleapis.com",
    "servicecontrol.googleapis.com",
    "apikeys.googleapis.com",
  ]
}

resource "google_project_service" "required" {
  for_each = toset(local.required_services)

  service = each.value
  # Leave APIs on if the stack is torn down; disabling them can break
  # unrelated resources in the project.
  disable_on_destroy = false
}

# Secrets are created out of band so their values never enter Terraform state.
data "google_secret_manager_secret" "spotify_client_id" {
  secret_id  = "spotify-client-id"
  depends_on = [google_project_service.required]
}

data "google_secret_manager_secret" "spotify_client_secret" {
  secret_id  = "spotify-client-secret"
  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# Cloud Run
# ---------------------------------------------------------------------------

resource "google_service_account" "runtime" {
  account_id   = "${var.service_name}-run"
  display_name = "Runtime identity for ${var.service_name}"
}

resource "google_secret_manager_secret_iam_member" "runtime_reads_id" {
  secret_id = data.google_secret_manager_secret.spotify_client_id.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_secret_manager_secret_iam_member" "runtime_reads_secret" {
  secret_id = data.google_secret_manager_secret.spotify_client_secret.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_cloud_run_v2_service" "app" {
  name     = var.service_name
  location = var.region

  # No allUsers binding below, so this stays private: only the gateway's
  # service account can invoke it, and rejections happen at Google's edge.
  ingress = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.runtime.email

    scaling {
      max_instance_count = var.max_instances
      min_instance_count = 0
    }

    containers {
      image = var.image

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        # Must be explicit. Setting `resources` at all makes Cloud Run require
        # this flag to keep request-based billing; omitting it switches the
        # service to instance-based billing, charging for the whole instance
        # lifetime instead of only while requests are in flight.
        cpu_idle = true

        # Extra CPU during container startup, billed only for that window.
        # Cuts the ~1.5s cold start that a scale-from-zero request pays.
        startup_cpu_boost = true
      }

      env {
        name = "SPOTIFY_CLIENT_ID"
        value_source {
          secret_key_ref {
            secret  = data.google_secret_manager_secret.spotify_client_id.secret_id
            version = "latest"
          }
        }
      }

      env {
        name = "SPOTIFY_CLIENT_SECRET"
        value_source {
          secret_key_ref {
            secret  = data.google_secret_manager_secret.spotify_client_secret.secret_id
            version = "latest"
          }
        }
      }
    }
  }

  depends_on = [google_project_service.required]
}

# ---------------------------------------------------------------------------
# API Gateway
# ---------------------------------------------------------------------------

resource "google_service_account" "gateway" {
  account_id   = "${var.service_name}-gw"
  display_name = "API Gateway invoker for ${var.service_name}"
}

# The only identity allowed to call Cloud Run.
resource "google_cloud_run_v2_service_iam_member" "gateway_invokes_app" {
  name     = google_cloud_run_v2_service.app.name
  location = google_cloud_run_v2_service.app.location
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.gateway.email}"
}

resource "google_api_gateway_api" "api" {
  provider = google-beta

  api_id       = var.service_name
  display_name = var.service_name

  depends_on = [google_project_service.required]
}

resource "google_api_gateway_api_config" "config" {
  provider = google-beta

  api = google_api_gateway_api.api.api_id
  # Configs are immutable: every change creates a new one and the gateway is
  # repointed at it, so the prefix + create_before_destroy pair is required.
  api_config_id_prefix = "cfg-"

  openapi_documents {
    document {
      path = "openapi.yaml"
      contents = base64encode(templatefile("${path.module}/openapi.yaml.tftpl", {
        api_title   = var.service_name
        backend_url = google_cloud_run_v2_service.app.uri
      }))
    }
  }

  gateway_config {
    backend_config {
      # Identity the gateway uses to mint an ID token for Cloud Run.
      google_service_account = google_service_account.gateway.email
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "google_api_gateway_gateway" "gateway" {
  provider = google-beta

  gateway_id = var.service_name
  api_config = google_api_gateway_api_config.config.id
  region     = var.region

  lifecycle {
    create_before_destroy = true
  }
}

# Enabling the generated managed service is what makes API key validation
# actually work. Doing it here removes the manual step that silently breaks
# key checking when forgotten.
resource "google_project_service" "managed_api" {
  service            = google_api_gateway_api.api.managed_service
  disable_on_destroy = false

  # The generated service config can take many minutes to become visible to
  # Service Usage after the API config is created. Depending on the gateway
  # pushes this attempt as late as possible in the graph; if it still races,
  # the fix is to re-run the apply, not to enable it by hand.
  depends_on = [google_api_gateway_gateway.gateway]
}

resource "google_apikeys_key" "gateway_key" {
  name         = "${var.service_name}-key"
  display_name = "${var.service_name} client key"

  restrictions {
    api_targets {
      service = google_api_gateway_api.api.managed_service
    }
  }

  depends_on = [google_project_service.managed_api]
}
