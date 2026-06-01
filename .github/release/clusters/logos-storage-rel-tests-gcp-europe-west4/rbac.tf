# In-cluster RBAC + kubeconfig for the release-tests runner.
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

# Token for the service account. The control plane's token controller populates
# .data.token; the provider waits for it (wait_for_service_account_token). The
# token is non-expiring but lives only as long as this transient cluster.
resource "kubernetes_secret" "release_tests_runner_token" {
  metadata {
    name      = "release-tests-runner-token"
    namespace = "default"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.release_tests_runner.metadata[0].name
    }
  }

  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
}

# Kubeconfig consumed by the in-cluster runner (mounted as KUBECONFIG by the Job).
resource "kubernetes_secret" "app_kubeconfig" {
  metadata {
    name      = "storage-dist-tests-app-kubeconfig"
    namespace = "default"
  }

  data = {
    "kubeconfig.yaml" = yamlencode({
      apiVersion      = "v1"
      kind            = "Config"
      current-context = "release-tests"
      clusters = [{
        name = "release-tests"
        cluster = {
          "certificate-authority-data" = module.gke.ca_certificate
          server                       = "https://${module.gke.endpoint}"
        }
      }]
      contexts = [{
        name = "release-tests"
        context = {
          cluster = "release-tests"
          user    = "release-tests-runner"
        }
      }]
      users = [{
        name = "release-tests-runner"
        user = {
          token = kubernetes_secret.release_tests_runner_token.data["token"]
        }
      }]
    })
  }
}
