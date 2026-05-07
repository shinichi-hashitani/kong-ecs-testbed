variable "region" {
  description = "AWS region for state backend and OIDC role."
  type        = string
  default     = "ap-northeast-1"
}

variable "project" {
  description = "Project name (used for naming S3 bucket / IAM role)."
  type        = string
  default     = "kong-ecs-testbed"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "dev"
}

variable "github_owner" {
  description = "GitHub org / user that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without owner)."
  type        = string
  default     = "kong-ecs-testbed"
}

variable "terraform_policy_name" {
  description = "Name of the Customer Managed Policy created in 0-setup that grants Terraform application permissions."
  type        = string
  default     = "kong-ecs-testbed-terraform"
}
