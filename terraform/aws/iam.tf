###############################################################################
# ECS Task Execution Role
#   - ECR からのイメージ pull
#   - CloudWatch Logs への書き込み
#   - Secrets Manager (Step 5 で Kong DP の cert/key を読み込む) への getSecretValue
###############################################################################
data "aws_iam_policy_document" "ecs_task_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "task_execution" {
  name               = "${local.name_prefix}-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

resource "aws_iam_role_policy_attachment" "task_execution_managed" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Step 5 で Secrets Manager に保存する Kong DP 証明書を読めるようにする
data "aws_iam_policy_document" "task_execution_secrets" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:aws:secretsmanager:${var.region}:*:secret:${local.name_prefix}/*",
    ]
  }
}

resource "aws_iam_role_policy" "task_execution_secrets" {
  name   = "${local.name_prefix}-task-exec-secrets"
  role   = aws_iam_role.task_execution.id
  policy = data.aws_iam_policy_document.task_execution_secrets.json
}

###############################################################################
# ECS Task Role
#   - ECS Exec 用の SSM Messages チャネル (enable_execute_command=true で必須)
###############################################################################
resource "aws_iam_role" "task" {
  name               = "${local.name_prefix}-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume.json
}

data "aws_iam_policy_document" "task_exec_ssm" {
  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_exec_ssm" {
  name   = "${local.name_prefix}-task-exec-ssm"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec_ssm.json
}
