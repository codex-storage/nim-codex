# In-cluster RBAC for the release-tests runner.
#
# The dist-tests Job runs inside this cluster and programmatically creates/deletes
# Kubernetes resources (storage-node pods) for each test, so it needs API
# credentials. Those are delivered via the storage-dist-tests-app-kubeconfig secret
# it mounts as KUBECONFIG.

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

