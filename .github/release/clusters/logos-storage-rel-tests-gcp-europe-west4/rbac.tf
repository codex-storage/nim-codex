# In-cluster RBAC for the release-tests runner.
#
# The dist-tests Job runs inside this cluster and programmatically creates/deletes
# Kubernetes resources (storage-node pods) for each test, so it needs API
# credentials. The Job runs under the release-tests-runner ServiceAccount, which
# Kubernetes automatically mounts as a short-lived projected token — no static
# kubeconfig or token Secret required.
#
# GCP IAM: the release-tests CI service account (used by the GitHub Actions
# workflow) also needs to delete orphaned GCE PersistentVolume disks after each
# test run. A least-privilege custom role is used instead of the overly broad
# roles/compute.storageAdmin.

# Least-privilege custom role: only the disk operations needed to clean up
# orphaned PVC-backed GCE disks after release test runs.
resource "google_project_iam_custom_role" "release_tests_disk_cleaner" {
  project     = var.project
  role_id     = "releaseTestsDiskCleaner"
  title       = "Release Tests Disk Cleaner"
  description = "Allows the release-tests CI SA to list and delete GCE persistent disks (for orphaned PVC cleanup)."
  permissions = [
    "compute.disks.delete",
    "compute.disks.list",
  ]
}

# Bind the custom disk-cleaner role to the release-tests GCP service account.
resource "google_project_iam_member" "release_tests_disk_cleaner" {
  project = var.project
  role    = google_project_iam_custom_role.release_tests_disk_cleaner.name
  member  = "serviceAccount:release-tests@${var.project}.iam.gserviceaccount.com"
}

resource "kubernetes_service_account" "release_tests_runner" {
  metadata {
    name      = "release-tests-runner"
    namespace = "default"
  }
}

resource "kubernetes_cluster_role_binding" "release_tests_runner" {
  metadata {
    name = "release-tests-runner"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.release_tests_runner.metadata[0].name
    namespace = kubernetes_service_account.release_tests_runner.metadata[0].namespace
  }
}

