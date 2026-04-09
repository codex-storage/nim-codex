# Kubernetes cluster
resource "digitalocean_kubernetes_cluster" "this" {
  name         = local.name
  region       = var.region
  version      = var.kubernetes_version
  ha           = var.kubernetes_ha
  auto_upgrade = var.kubernetes_auto_upgrade

  node_pool {
    name       = var.kubernetes_node_pool_name
    size       = var.kubernetes_node_pool_size
    node_count = var.kubernetes_node_pool_count
    auto_scale = var.kubernetes_node_pool_auto_scale
    min_nodes  = var.kubernetes_node_pool_min
    max_nodes  = var.kubernetes_node_pool_max
    tags       = var.kubernetes_node_pool_tags
    labels     = var.kubernetes_node_pool_labels

    dynamic "taint" {
      for_each = length(var.kubernetes_node_pool_taint) == 0 ? {} : { taint = true }
      content {
        key    = lookup(var.kubernetes_node_pool_taint, "key")
        value  = lookup(var.kubernetes_node_pool_taint, "value")
        effect = lookup(var.kubernetes_node_pool_taint, "effect")
      }
    }
  }

  maintenance_policy {
    day        = var.kubernetes_maintenance_day
    start_time = var.kubernetes_maintenance_start_time
  }
}
