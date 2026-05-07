provider "aws" {
  region = var.region
  # AWS_PROFILE is read from the environment (set in .env, default: "kong-testbed").
  default_tags {
    tags = local.common_tags
  }
}
