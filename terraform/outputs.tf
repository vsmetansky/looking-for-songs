output "gateway_url" {
  description = "Base URL clients call."
  value       = "https://${google_api_gateway_gateway.gateway.default_hostname}"
}

output "cloud_run_url" {
  description = "Private backend URL; requires auth, not for clients."
  value       = google_cloud_run_v2_service.app.uri
}

output "api_key" {
  description = "Key for the Shortcut. Read with: terraform output -raw api_key"
  value       = google_apikeys_key.gateway_key.key_string
  sensitive   = true
}
