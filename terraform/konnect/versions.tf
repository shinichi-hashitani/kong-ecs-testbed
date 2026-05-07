terraform {
  required_version = ">= 1.6.0"

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
