output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state. Set as GitHub repo variable TF_STATE_BUCKET."
  value       = aws_s3_bucket.tfstate.id
}

output "state_lock_table_name" {
  description = "DynamoDB table for Terraform state locks. Set as GitHub repo variable TF_LOCK_TABLE."
  value       = aws_dynamodb_table.tflocks.id
}

output "github_actions_role_arn" {
  description = "ARN of the IAM Role assumed by GitHub Actions. Set as GitHub repo secret AWS_ROLE_ARN."
  value       = aws_iam_role.github_actions.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider."
  value       = aws_iam_openid_connect_provider.github.arn
}
