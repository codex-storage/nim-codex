# Both node pools are inline so GCP provisions them in parallel during
# cluster creation, avoiding the sequential create penalty of a separate
# google_container_node_pool resource.
resource "google_container_cluster" "this" {
  name     = local.name
  location = var.zone
  project  = var.project

  deletion_protection = false

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
