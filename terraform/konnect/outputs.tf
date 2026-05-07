output "control_plane_id" {
  description = "Konnect Control Plane ID."
  value       = konnect_gateway_control_plane.this.id
}

output "control_plane_endpoint" {
  description = "Telemetry/cluster endpoint for the Control Plane (used by DP KONG_CLUSTER_CONTROL_PLANE)."
  value       = konnect_gateway_control_plane.this.config.control_plane_endpoint
}

output "telemetry_endpoint" {
  description = "Telemetry endpoint (used by DP KONG_CLUSTER_TELEMETRY_ENDPOINT)."
  value       = konnect_gateway_control_plane.this.config.telemetry_endpoint
}

output "dp_certificate_pem" {
  description = "PEM-encoded DP client certificate. Mount into DP via Secrets Manager."
  value       = tls_self_signed_cert.dp.cert_pem
  sensitive   = true
}

output "dp_private_key_pem" {
  description = "PEM-encoded DP private key. Mount into DP via Secrets Manager."
  value       = tls_private_key.dp.private_key_pem
  sensitive   = true
}
