data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

locals {
  # bootstrap module が作る remote state バケット名と同じ規則
  state_bucket_name = "${var.project_name}-tfstate-${data.aws_caller_identity.current.account_id}"
}

# terraform/konnect の出力を参照する。Step 5 (Kong DP) で cert/key/endpoint を使う。
data "terraform_remote_state" "konnect" {
  backend = "s3"
  config = {
    bucket = local.state_bucket_name
    key    = "konnect/terraform.tfstate"
    region = var.region
  }
}
