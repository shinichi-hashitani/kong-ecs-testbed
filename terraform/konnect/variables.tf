variable "konnect_pat" {
  description = "Konnect Personal Access Token. Pass via TF_VAR_konnect_pat env var."
  type        = string
  sensitive   = true
}

variable "konnect_server_url" {
  description = "Konnect API server URL (Geo-specific). US Geo = https://us.api.konghq.com"
  type        = string
  default     = "https://us.api.konghq.com"
}

variable "cp_name" {
  description = "Name of the Konnect Control Plane to create."
  type        = string
  default     = "kong-ecs-testbed-cp"
}

variable "cp_description" {
  description = "Description for the Control Plane."
  type        = string
  default     = "Test CP for kong-ecs-testbed (ECS Fargate Hybrid DP)."
}

variable "labels" {
  description = "Labels to attach to the Control Plane."
  type        = map(string)
  default = {
    project = "kong-ecs-testbed"
    env     = "dev"
  }
}
