# Both node pools are inline in the module so GCP provisions them in parallel.
module "gke" {
  source = "../modules/gke"

  name    = local.name
  project = var.project
  region  = var.region
  zone    = var.zone

  network    = google_compute_network.this.id
  subnetwork = google_compute_subnetwork.this.id

  pods_range_name     = "pods"
  services_range_name = "services"

  master_ipv4_cidr_block = "172.16.0.0/28"

  node_pool_name         = "runners-ci-e2-standard-2"
  node_pool_machine_type = "e2-standard-2"
  node_pool_count        = 1
  node_pool_labels = {
    default-pool  = "true"
    scaling-type  = "fixed"
    workload-type = "tests-runners-ci"
  }

  tests_pool_name         = "tests-e2-medium"
  tests_pool_machine_type = "e2-medium"
  tests_pool_count        = 11
  tests_pool_labels = {
    default-pool  = "false"
    scaling-type  = "fixed"
    workload-type = "tests-pods"
  }
}
