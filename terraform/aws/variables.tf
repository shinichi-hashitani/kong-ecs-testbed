variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-northeast-1"
}

variable "project_name" {
  description = "Prefix used for all resource names."
  type        = string
  default     = "kong-ecs-testbed"
}

variable "environment" {
  description = "Environment tag."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ)."
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "allowed_cidrs" {
  description = "Source CIDRs allowed to reach the ALB on HTTP/80. Restrict to office/home IP for testing."
  type        = list(string)
  # NOTE: 0.0.0.0/0 is intentionally NOT the default to avoid accidental wide exposure.
  # Set in terraform.tfvars or via -var.
}

variable "private_dns_namespace" {
  description = "Cloud Map private DNS namespace. Kong Service host targets like httpbin.<namespace>."
  type        = string
  default     = "kong-ecs-testbed.local"
}

variable "konnect_state_path" {
  description = "Relative path to the terraform/konnect tfstate file (read via terraform_remote_state)."
  type        = string
  default     = "../konnect/terraform.tfstate"
}

# ---- httpbin (Step 4) ----
variable "httpbin_image" {
  description = "Container image for httpbin."
  type        = string
  default     = "kennethreitz/httpbin:latest"
}

variable "httpbin_desired_count" {
  description = "Desired task count for httpbin."
  type        = number
  default     = 1
}

# ---- Kong DP (Step 5) ----
variable "kong_dp_image" {
  description = "Container image for Kong Gateway DP."
  type        = string
  default     = "kong/kong-gateway:3.8"
}

variable "kong_dp_desired_count" {
  description = "Desired task count for Kong DP."
  type        = number
  default     = 1
}
