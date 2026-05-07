###############################################################################
# Security Groups
###############################################################################

# ALB: allowed_cidrs から HTTP/80 を受け、DP SG へ抜ける
resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb"
  description = "ALB ingress from allowed CIDRs (HTTP)"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTP from allowed sources"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    description = "All egress (to DP)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-alb" }
}

# Kong DP: ALB SG から 8000 (proxy)、8100 (status) を受ける
# Egress: Konnect CP (TLS), httpbin SG, ECR/Docker Hub
resource "aws_security_group" "dp" {
  name        = "${local.name_prefix}-dp"
  description = "Kong Gateway Data Plane"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "Proxy port from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Status/health port from ALB"
    from_port       = 8100
    to_port         = 8100
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All egress (Konnect CP / image pull / upstream)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-dp" }
}

# httpbin: DP SG からのみ 80 を受ける
resource "aws_security_group" "httpbin" {
  name        = "${local.name_prefix}-httpbin"
  description = "httpbin upstream"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "HTTP from Kong DP"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.dp.id]
  }

  egress {
    description = "All egress (image pull)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${local.name_prefix}-httpbin" }
}
