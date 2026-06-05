variable "project" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region (e.g. europe-west4)"
  type        = string
}

variable "zone" {
  description = "GCP zone for the cluster (e.g. europe-west4-b)"
  type        = string
}
