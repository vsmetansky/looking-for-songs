variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "region" {
  type        = string
  description = "Region for Cloud Run and the gateway."
  default     = "us-east1"
}

variable "service_name" {
  type        = string
  description = "Name shared by the Cloud Run service, API, and gateway."
  default     = "looking-for-songs"
}

variable "image" {
  type        = string
  description = "Fully qualified container image, passed in by CI per commit."
}

variable "max_instances" {
  type        = number
  description = "Hard ceiling on scale-out. This is the cost cap; keep it small."
  default     = 1
}

variable "keep_warm_schedule" {
  type        = string
  description = "Cron for the keep-warm ping. Cloud Run's idle retention is undocumented but observed around 15m, so 5m leaves roughly 3x margin."
  default     = "*/5 * * * *"
}
