###############################################################################
# httpbin ECS Service (Step 4)
# - Cloud Map に "httpbin.<namespace>" として A レコード登録
# - Public Subnet + assign_public_ip=true（NAT 不在のため image pull に必要）
###############################################################################
resource "aws_cloudwatch_log_group" "httpbin" {
  name              = "/ecs/${local.name_prefix}/httpbin"
  retention_in_days = 7
}

resource "aws_service_discovery_service" "httpbin" {
  name = "httpbin"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.this.id
    routing_policy = "MULTIVALUE"

    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

resource "aws_ecs_task_definition" "httpbin" {
  family                   = "${local.name_prefix}-httpbin"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  execution_role_arn       = aws_iam_role.task_execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    {
      name      = "httpbin"
      image     = var.httpbin_image
      essential = true

      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.httpbin.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "httpbin" {
  name            = "${local.name_prefix}-httpbin"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.httpbin.arn
  desired_count   = var.httpbin_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.httpbin.id]
    assign_public_ip = true
  }

  service_registries {
    registry_arn = aws_service_discovery_service.httpbin.arn
  }

  enable_execute_command = true

  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 200
}
