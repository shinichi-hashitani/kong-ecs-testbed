###############################################################################
# Cloud Map (Service Discovery) - Private DNS Namespace
# Kong DP は Service の host を `httpbin.<namespace>` で解決する想定。
# 実際の SD Service (httpbin 用) は Step 4 で作る。
###############################################################################
resource "aws_service_discovery_private_dns_namespace" "this" {
  name = var.private_dns_namespace
  vpc  = aws_vpc.this.id

  description = "Private DNS namespace for ${local.name_prefix}"
}
