# Kubernetes cluster
output "kubernetes_cluster_id" {
  value       = google_container_cluster.this.id
  description = "The fully-qualified ID of the GKE cluster."
}

output "kubernetes_cluster_name" {
  value       = google_container_cluster.this.name
  description = "The name of the GKE cluster."
}

output "endpoint" {
  value       = google_container_cluster.this.endpoint
  description = "The IP address of the cluster's Kubernetes API server."
}

output "ca_certificate" {
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  description = "Base64-encoded public CA certificate of the cluster's API server."
  sensitive   = true
}
