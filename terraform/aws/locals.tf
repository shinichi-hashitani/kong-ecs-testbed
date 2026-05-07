locals {
  name_prefix = var.project_name

  common_tags = {
    Project   = var.project_name
    Env       = var.environment
    ManagedBy = "Terraform"
  }
}
