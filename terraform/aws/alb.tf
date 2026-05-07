###############################################################################
# ALB (Internet-facing, HTTP only)
# Target Group / Listener Rule は Step 5 (Kong DP) で追加する。
# このファイルでは ALB 本体と既定 Listener (404) のみ定義する。
###############################################################################
resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  idle_timeout = 60
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "no route matched (default)"
      status_code  = "404"
    }
  }
}
