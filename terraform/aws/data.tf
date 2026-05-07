data "aws_availability_zones" "available" {
  state = "available"
}

# terraform/konnect の出力を参照する。Step 5 (Kong DP) で cert/key/endpoint を使う。
data "terraform_remote_state" "konnect" {
  backend = "local"
  config = {
    path = var.konnect_state_path
  }
}
