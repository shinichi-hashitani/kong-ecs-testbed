terraform {
  required_version = ">= 1.6.0"

  # Partial backend configuration: bucket / key / region / dynamodb_table are
  # supplied via `terraform init -backend-config="..."` (see 1-gitops.md).
  backend "s3" {}

  required_providers {
    konnect = {
      source  = "kong/konnect"
      version = "~> 2.2"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
