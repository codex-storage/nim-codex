# Kubernetes cluster — runners-ci pool configured inline to avoid the
# remove_default_node_pool create-then-delete cycle that adds ~5 min.
resource "google_container_cluster" "this" {
  name     = local.name
  location = var.zone
  project  = var.project

  deletion_protection = false

  # Send pod stdout/stderr to Cloud Logging automatically
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "none"

  node_pool {
    name               = var.node_pool_name
    initial_node_count = var.node_pool_min

    autoscaling {
      min_node_count = var.node_pool_min
      max_node_count = var.node_pool_max
    }

    node_config {
      machine_type = var.node_pool_machine_type
      labels       = var.node_pool_labels

      oauth_scopes = [
        "https://www.googleapis.com/auth/cloud-platform",
      ]
    }
  }
}
