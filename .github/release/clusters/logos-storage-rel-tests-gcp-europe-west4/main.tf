# Kubernetes cluster — runners-ci pool is configured inline in the module
module "gke" {
  source = "../modules/gke"

  name                       = "logos-storage-rel-tests"
  project                    = var.project
  region                     = var.region
  zone                       = var.zone
  kubernetes_release_channel = "STABLE"
  node_pool_name             = "runners-ci-e2-standard-2"
  node_pool_machine_type     = "e2-standard-2"
  node_pool_min              = 1
  node_pool_max              = 5
  node_pool_labels = {
    allow-tests-pods = "false"
    default-pool     = "true"
    scaling-type     = "auto"
    workload-type    = "tests-runners-ci"
  }
}

# Node pool - Tests Pods
resource "google_container_node_pool" "tests-pods" {
  name     = "tests-e2-medium"
  cluster  = module.gke.kubernetes_cluster_id
  location = var.zone
  project  = var.project

  autoscaling {
    min_node_count = 0
    max_node_count = 10
  }

  node_config {
    machine_type = "e2-medium"
    spot         = true
    labels = {
      allow-tests-pods = "true"
      default-pool     = "false"
      scaling-type     = "auto"
      workload-type    = "tests-pods"
    }
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}
