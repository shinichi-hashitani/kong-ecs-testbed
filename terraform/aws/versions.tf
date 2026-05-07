terraform {
  required_version = ">= 1.10.0"

  # Partial backend configuration: bucket / key / region / dynamodb_table are
  # supplied via `terraform init -backend-config="..."` (see 1-gitops.md).
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}
