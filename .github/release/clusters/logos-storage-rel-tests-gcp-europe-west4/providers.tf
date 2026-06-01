# Providers
provider "google" {
  project = var.project
  region  = var.region
}

# Used to authenticate the kubernetes provider against the cluster created in
# this same apply (short-lived OAuth access token from the active gcloud creds).
data "google_client_config" "default" {}

provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
  token                  = data.google_client_config.default.access_token
}
