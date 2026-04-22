terraform {
  backend "gcs" {
    prefix = "clusters/logos-storage-dist-tests-gcp-europe-west4"
    # bucket is supplied at init time via:
    #   terraform init -backend-config="bucket=<bucket-name>"
  }
}
