# Kubernetes cluster
output "kubernetes_cluster_id" {
  value       = google_container_cluster.this.id
  description = "The fully-qualified ID of the GKE cluster."
}

output "kubernetes_cluster_name" {
  value       = google_container_cluster.this.name
  description = "The name of the GKE cluster."
}
