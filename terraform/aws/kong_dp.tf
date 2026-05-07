###############################################################################
# Kong Gateway Data Plane (Step 5)
#
# 構成:
#   - Konnect TF が発行した cert/key を AWS Secrets Manager に保存
#   - ECS Task Definition の secrets ディレクティブで KONG_CLUSTER_CERT /
#     KONG_CLUSTER_CERT_KEY に PEM 文字列を直接注入
#     （Kong は env 値が PEM の場合ファイルに書き出さなくても動作する）
#   - ALB Target Group を作り、HTTP/80 リスナーから 8000 にフォワード
###############################################################################

# Konnect endpoint URL から host 部分を取り出す
locals {
  cp_endpoint_url        = data.terraform_remote_state.konnect.outputs.control_plane_endpoint
  telemetry_endpoint_url = data.terraform_remote_state.konnect.outputs.telemetry_endpoint

  cp_endpoint_host        = regex("^(?:https?://)?([^/:]+)", local.cp_endpoint_url)[0]
  telemetry_endpoint_host = regex("^(?:https?://)?([^/:]+)", local.telemetry_endpoint_url)[0]
}

###############################################################################
# Secrets Manager: cert / key
###############################################################################
resource "aws_secretsmanager_secret" "dp_cert" {
  name                    = "${local.name_prefix}/dp-certificate"
  description             = "Kong DP client certificate (PEM)."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "dp_cert" {
  secret_id     = aws_secretsmanager_secret.dp_cert.id
  secret_string = data.terraform_remote_state.konnect.outputs.dp_certificate_pem
}

resource "aws_secretsmanager_secret" "dp_key" {
  name                    = "${local.name_prefix}/dp-private-key"
  description             = "Kong DP private key (PEM)."
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "dp_key" {
  secret_id     = aws_secretsmanager_secret.dp_key.id
  secret_string = data.terraform_remote_state.konnect.outputs.dp_private_key_pem
}

###############################################################################
# CloudWatch Logs
###############################################################################
resource "aws_cloudwatch_log_group" "kong_dp" {
  name              = "/ecs/${local.name_prefix}/kong-dp"
  retention_in_days = 7
}

###############################################################################
# Task Definition
###############################################################################
resource "aws_ecs_task_definition" "kong_dp" {
  family                   = "${local.name_prefix}-kong-dp"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "kong"
      image     = var.kong_dp_image
      essential = true

      portMappings = [
        { containerPort = 8000, protocol = "tcp" }, # proxy
        { containerPort = 8100, protocol = "tcp" }, # status
      ]

      environment = [
        { name = "KONG_ROLE", value = "data_plane" },
        { name = "KONG_DATABASE", value = "off" },
        { name = "KONG_VITALS", value = "off" },
        { name = "KONG_KONNECT_MODE", value = "on" },

        { name = "KONG_CLUSTER_MTLS", value = "pki" },
        { name = "KONG_CLUSTER_CONTROL_PLANE", value = "${local.cp_endpoint_host}:443" },
        { name = "KONG_CLUSTER_SERVER_NAME", value = local.cp_endpoint_host },
        { name = "KONG_CLUSTER_TELEMETRY_ENDPOINT", value = "${local.telemetry_endpoint_host}:443" },
        { name = "KONG_CLUSTER_TELEMETRY_SERVER_NAME", value = local.telemetry_endpoint_host },
        { name = "KONG_LUA_SSL_TRUSTED_CERTIFICATE", value = "system" },

        { name = "KONG_PROXY_LISTEN", value = "0.0.0.0:8000" },
        { name = "KONG_STATUS_LISTEN", value = "0.0.0.0:8100" },
        { name = "KONG_PROXY_ACCESS_LOG", value = "/dev/stdout" },
        { name = "KONG_PROXY_ERROR_LOG", value = "/dev/stderr" },
        { name = "KONG_ADMIN_ACCESS_LOG", value = "/dev/stdout" },
        { name = "KONG_ADMIN_ERROR_LOG", value = "/dev/stderr" },
      ]

      # PEM 文字列を直接 KONG_CLUSTER_CERT* に注入（Kong は値が PEM ならファイル化不要）
      secrets = [
        { name = "KONG_CLUSTER_CERT", valueFrom = aws_secretsmanager_secret.dp_cert.arn },
        { name = "KONG_CLUSTER_CERT_KEY", valueFrom = aws_secretsmanager_secret.dp_key.arn },
      ]

      healthCheck = {
        command     = ["CMD-SHELL", "kong health || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 5
        startPeriod = 60
      }

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.kong_dp.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])

  depends_on = [
    aws_secretsmanager_secret_version.dp_cert,
    aws_secretsmanager_secret_version.dp_key,
  ]
}

###############################################################################
# ALB Target Group + Listener Rule
###############################################################################
resource "aws_lb_target_group" "kong_dp" {
  name        = "${local.name_prefix}-dp-tg"
  vpc_id      = aws_vpc.this.id
  port        = 8000
  protocol    = "HTTP"
  target_type = "ip"

  deregistration_delay = 15

  health_check {
    enabled = true
    # /status/ready は DP が CP と接続しコンフィグを受領済みのときのみ 200 を返す
    path                = "/status/ready"
    port                = "8100"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener_rule" "kong_dp" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kong_dp.arn
  }

  condition {
    path_pattern {
      values = ["/*"]
    }
  }
}

###############################################################################
# ECS Service
###############################################################################
resource "aws_ecs_service" "kong_dp" {
  name            = "${local.name_prefix}-kong-dp"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.kong_dp.arn
  desired_count   = var.kong_dp_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.dp.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.kong_dp.arn
    container_name   = "kong"
    container_port   = 8000
  }

  enable_execute_command = true

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200

  health_check_grace_period_seconds = 90

  depends_on = [aws_lb_listener_rule.kong_dp]
}
