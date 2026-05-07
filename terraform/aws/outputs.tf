output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "ecs_cluster_arn" {
  value = aws_ecs_cluster.this.arn
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "alb_dns_name" {
  description = "Public DNS of the ALB. Send test traffic here in Step 7."
  value       = aws_lb.this.dns_name
}

output "alb_listener_arn" {
  value = aws_lb_listener.http.arn
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "dp_security_group_id" {
  value = aws_security_group.dp.id
}

output "httpbin_security_group_id" {
  value = aws_security_group.httpbin.id
}

output "task_execution_role_arn" {
  value = aws_iam_role.task_execution.arn
}

output "service_discovery_namespace_id" {
  value = aws_service_discovery_private_dns_namespace.this.id
}

output "service_discovery_namespace_name" {
  value = aws_service_discovery_private_dns_namespace.this.name
}

output "kong_dp_log_group" {
  value = aws_cloudwatch_log_group.kong_dp.name
}

output "httpbin_log_group" {
  value = aws_cloudwatch_log_group.httpbin.name
}

output "kong_dp_target_group_arn" {
  value = aws_lb_target_group.kong_dp.arn
}
