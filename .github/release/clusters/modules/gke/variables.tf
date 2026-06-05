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

variable "node_pool_count" {
  type        = number
  description = "Fixed number of nodes in the default pool."
}

variable "node_pool_labels" {
  type        = map(string)
  description = "A map of key/value pairs to apply as Kubernetes labels to nodes in the default pool."
  default = {
    default-pool = "true"
    scaling-type = "fixed"
  }
}

# Tests node pool (fixed size, single zone)
variable "tests_pool_name" {
  type        = string
  description = "Name for the tests node pool."
}

variable "tests_pool_machine_type" {
  type        = string
  description = "The GCE machine type for nodes in the tests pool."
}

variable "tests_pool_count" {
  type        = number
  description = "Fixed number of nodes in the tests pool (no autoscaling; this is a transient cluster)."
}

variable "tests_pool_labels" {
  type        = map(string)
  description = "Kubernetes labels to apply to nodes in the tests pool."
  default     = {}
}
