# Kubernetes cluster
module "doks" {
  source = "../modules/doks"

  name                            = "logos-storage-dist-tests"
  region                          = var.region
  kubernetes_version              = "1.34.5-do.2"
  kubernetes_ha                   = true
  kubernetes_auto_upgrade         = false
  kubernetes_node_pool_name       = "infra-s-4vcpu-16gb-amd"
  kubernetes_node_pool_size       = "s-4vcpu-16gb-amd"
  kubernetes_node_pool_auto_scale = true
  kubernetes_node_pool_min        = 1
  kubernetes_node_pool_max        = 3
  kubernetes_node_pool_tags       = ["default", "autoscale"]
  kubernetes_node_pool_labels = {
    default-pool  = "true"
    scaling-type  = "auto"
    workload-type = "infra"
  }
}

# Node pool - Runners CI
resource "digitalocean_kubernetes_node_pool" "runners-ci" {
  cluster_id = module.doks.kubernetes_cluster_id
  name       = "runners-ci-s-2vcpu-8gb-amd"
  size       = "s-2vcpu-8gb-amd"
  auto_scale = true
  min_nodes  = 1
  max_nodes  = 5
  tags       = ["runners-ci"]

  labels = {
    allow-tests-pods = "false"
    default-pool     = "false"
    scaling-type     = "auto"
    workload-type    = "tests-runners-ci"
  }
}

# Node pool - Tests Pods
resource "digitalocean_kubernetes_node_pool" "tests-s-2vcpu-4gb" {
  cluster_id = module.doks.kubernetes_cluster_id
  name       = "tests-s-2vcpu-4gb"
  size       = "s-2vcpu-4gb"
  auto_scale = true
  min_nodes  = 1
  max_nodes  = 10
  tags       = ["tests-pods"]

  labels = {
    allow-tests-pods = "true"
    default-pool     = "false"
    scaling-type     = "auto"
    workload-type    = "tests-pods"
  }
}
