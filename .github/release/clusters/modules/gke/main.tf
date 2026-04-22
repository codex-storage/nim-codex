# Kubernetes cluster
resource "google_container_cluster" "this" {
  name     = local.name
  location = var.region
  project  = var.project

  # Create an empty cluster — all node pools are managed as separate resources
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false

  release_channel {
    channel = var.kubernetes_release_channel
  }

  # Enable Workload Identity
  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }

  # Send pod stdout/stderr to Cloud Logging automatically
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"
}

# Default (infra) node pool
resource "google_container_node_pool" "default" {
  name     = var.node_pool_name
  cluster  = google_container_cluster.this.id
  location = var.region
  project  = var.project

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
