# Both node pools are inline in the module so GCP provisions them in parallel.
module "gke" {
  source = "../modules/gke"

  name    = "logos-storage-rel-tests"
  project = var.project
  region  = var.region
  zone    = var.zone

  node_pool_name         = "runners-ci-e2-standard-2"
  node_pool_machine_type = "e2-standard-2"
  node_pool_min          = 1
  node_pool_max          = 5
  node_pool_labels = {
    default-pool  = "true"
    scaling-type  = "auto"
    workload-type = "tests-runners-ci"
  }

  tests_pool_name         = "tests-e2-medium"
  tests_pool_machine_type = "e2-medium"
  tests_pool_max          = 10
  tests_pool_labels = {
    default-pool  = "false"
    scaling-type  = "auto"
    workload-type = "tests-pods"
  }
}
