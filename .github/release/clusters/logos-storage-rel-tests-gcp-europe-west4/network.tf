# Custom VPC + subnet, required for private GKE nodes (enable_private_nodes
# in main.tf). Without this, nodes would use the default network with no
# secondary ranges available for VPC-native pod/service IPs.
resource "google_compute_network" "this" {
  name                    = "${local.name}-vpc"
  project                 = var.project
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "this" {
  name          = "${local.name}-subnet"
  project       = var.project
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = "10.10.0.0/20"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/14"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# Cloud Router + NAT: gives private nodes outbound internet access (pulling
# container images, apt packages, etc.) since they have no external IPs.
resource "google_compute_router" "this" {
  name    = "${local.name}-router"
  project = var.project
  region  = var.region
  network = google_compute_network.this.id
}

resource "google_compute_router_nat" "this" {
  name    = "${local.name}-nat"
  project = var.project
  router  = google_compute_router.this.name
  region  = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}
