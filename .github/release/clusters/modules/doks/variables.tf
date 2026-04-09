# Main
variable "name" {
  type        = string
  description = "A name for the created resources."
}

variable "region" {
  type        = string
  description = "The DigitalOcean region slug for the resources location."
}

# Kubernetes Control Plane
variable "kubernetes_version" {
  type        = string
  description = "The slug identifier for the version of Kubernetes used for the cluster."
}

variable "kubernetes_ha" {
  type        = bool
  description = "Enable/disable the high availability control plane for a cluster."
}

variable "kubernetes_auto_upgrade" {
  type        = bool
  description = "A boolean value indicating whether the cluster will be automatically upgraded to new patch releases during its maintenance window."
}

variable "kubernetes_maintenance_day" {
  type        = string
  description = "The day of the maintenance window policy."
  default     = "sunday"
}

variable "kubernetes_maintenance_start_time" {
  type        = string
  description = "The start time in UTC of the maintenance window policy in 24-hour clock format / HH:MM notation (e.g., 15:00)."
  default     = "04:00"
}

# Kubernetes default Node Pool
variable "kubernetes_node_pool_name" {
  type        = string
  description = "A name for the node pool."
  default     = null
}

variable "kubernetes_node_pool_size" {
  type        = string
  description = "The slug identifier for the type of Droplet to be used as workers in the node pool."
  default     = null
}

variable "kubernetes_node_pool_count" {
  type        = number
  default     = null
  description = "The number of Droplet instances in the node pool."
}

variable "kubernetes_node_pool_auto_scale" {
  type        = bool
  description = "Enable auto-scaling of the number of nodes in the node pool within the given min/max range."
  default     = null
}

variable "kubernetes_node_pool_min" {
  type        = number
  description = "If auto-scaling is enabled, this represents the minimum number of nodes that the node pool can be scaled down to."
  default     = null
}

variable "kubernetes_node_pool_max" {
  type        = number
  description = "If auto-scaling is enabled, this represents the maximum number of nodes that the node pool can be scaled up to."
  default     = null
}

variable "kubernetes_node_pool_tags" {
  type        = list(any)
  description = "A list of tag names applied to the node pool."
  default     = ["default", "autoscale"]
}

variable "kubernetes_node_pool_labels" {
  type        = map(string)
  description = "A map of key/value pairs to apply to nodes in the pool."
  default = {
    default-pool = "true"
    scaling-type = "auto"
  }
}

variable "kubernetes_node_pool_taint" {
  type        = map(string)
  description = "A block representing a taint applied to all nodes in the pool."
  default = {
  }
}
