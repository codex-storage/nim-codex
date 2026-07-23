# Both node pools are inline so GCP provisions them in parallel during
# cluster creation, avoiding the sequential create penalty of a separate
# google_container_node_pool resource.
resource "google_container_cluster" "this" {
  name     = local.name
  location = var.zone
  project  = var.project

  deletion_protection = false

  network    = var.network
  subnetwork = var.subnetwork

  # VPC-native cluster, required for private nodes.
  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  # Nodes get only internal IPs, avoiding the per-region IN_USE_ADDRESSES
  # quota. The control plane keeps its public endpoint (no
  # master_authorized_networks_config) so the GitHub-hosted CI runner can
  # still reach it.
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block
  }

  # Send pod stdout/stderr to Cloud Logging automatically
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  timeouts {
    create = "20m"
  }

  node_pool {
    name       = var.node_pool_name
    node_count = var.node_pool_count

    node_config {
      machine_type = var.node_pool_machine_type
      disk_size_gb = 50
      labels       = var.node_pool_labels

      oauth_scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
      ]
    }
  }

  node_pool {
    name       = var.tests_pool_name
    node_count = var.tests_pool_count

    node_config {
      machine_type = var.tests_pool_machine_type
      disk_size_gb = 20
      labels       = var.tests_pool_labels

      oauth_scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
      ]
    }
  }
}
