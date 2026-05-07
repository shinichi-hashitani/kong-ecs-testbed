###############################################################################
# Konnect Control Plane (Hybrid)
###############################################################################
resource "konnect_gateway_control_plane" "this" {
  name         = var.cp_name
  description  = var.cp_description
  cluster_type = "CLUSTER_TYPE_HYBRID"
  # PKI mTLS: DP は自前で生成した client cert を使って CP に接続する
  auth_type = "pki_client_certs"
  labels    = var.labels
}

###############################################################################
# Data Plane mTLS client certificate (self-signed, leaf only)
#
# Konnect の PKI mode では、ユーザー側で生成した証明書を Konnect に登録し、
# DP コンテナにマウントすることで mTLS 接続を確立する。
###############################################################################
resource "tls_private_key" "dp" {
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "dp" {
  private_key_pem = tls_private_key.dp.private_key_pem

  subject {
    common_name  = "kong-ecs-testbed-dp"
    organization = "kong-ecs-testbed"
  }

  # 1 年。テスト用途。
  validity_period_hours = 8760
  early_renewal_hours   = 720

  allowed_uses = [
    "client_auth",
    "key_encipherment",
    "digital_signature",
  ]
}

resource "konnect_gateway_data_plane_client_certificate" "dp" {
  control_plane_id = konnect_gateway_control_plane.this.id
  cert             = tls_self_signed_cert.dp.cert_pem
}
