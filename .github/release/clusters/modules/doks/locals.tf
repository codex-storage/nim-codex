locals {
  name           = "${var.name}-do-${var.region}"
  node_pool_name = "pool-${var.kubernetes_node_pool_size}"
}
