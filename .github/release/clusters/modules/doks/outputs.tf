# Kubernetes cluster
output "kubernetes_cluster_id" {
  value       = digitalocean_kubernetes_cluster.this.id
  description = "A unique ID that can be used to identify and reference a Kubernetes cluster."
}
