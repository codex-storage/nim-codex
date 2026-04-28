# Main
variable "name" {
  type        = string
  description = "A name for the created resources."
}

variable "project" {
  type        = string
  description = "The GCP project ID."
}

variable "region" {
  type        = string
  description = "The GCP region (used for the provider and node pool location)."
}

variable "zone" {
  type        = string
  description = "The GCP zone for the cluster. Using a single zone avoids the longer provisioning time of a regional (multi-zone) cluster."
}

# Kubernetes default Node Pool
variable "node_pool_name" {
  type        = string
  description = "A name for the default node pool."
}

variable "node_pool_machine_type" {
  type        = string
  description = "The GCE machine type for nodes in the default pool."
}

variable "node_pool_min" {
  type        = number
  description = "Minimum number of nodes per zone in the default pool (autoscaling)."
}

variable "node_pool_max" {
  type        = number
  description = "Maximum number of nodes per zone in the default pool (autoscaling)."
}

variable "node_pool_labels" {
  type        = map(string)
  description = "A map of key/value pairs to apply as Kubernetes labels to nodes in the default pool."
  default = {
    default-pool = "true"
    scaling-type = "auto"
  }
}
