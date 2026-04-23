# Kubernetes cluster
module "gke" {
  source = "../modules/gke"

  name                       = "logos-storage-rel-tests"
  project                    = var.project
  region                     = var.region
  zone                       = var.zone
  kubernetes_release_channel = "STABLE"
  node_pool_name             = "infra-e2-standard-4"
  node_pool_machine_type     = "e2-standard-4"
  node_pool_min              = 1
  node_pool_max              = 3
  node_pool_labels = {
    default-pool  = "true"
    scaling-type  = "auto"
    workload-type = "infra"
  }
}

# Node pool - Runners CI
resource "google_container_node_pool" "runners-ci" {
  name     = "runners-ci-e2-standard-2"
  cluster  = module.gke.kubernetes_cluster_id
  location = var.zone
  project  = var.project

  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  node_config {
    machine_type = "e2-standard-2"
    labels = {
      allow-tests-pods = "false"
      default-pool     = "false"
      scaling-type     = "auto"
      workload-type    = "tests-runners-ci"
    }
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]
  }
}

# Node pool - Tests Pods
resource "google_container_node_pool" "tests-pods" {
  name     = "tests-e2-medium"
  cluster  = module.gke.kubernetes_cluster_id
  location = var.zone
  project  = var.project

  autoscaling {
    min_node_count = 1
    max_node_count = 10
  }

  node_config {
    machine_type = "e2-medium"
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
