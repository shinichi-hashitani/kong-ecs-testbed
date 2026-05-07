output "state_bucket_name" {
  description = "S3 bucket holding Terraform remote state (also stores S3-native lock files). Set as GitHub repo variable TF_STATE_BUCKET."
  value       = aws_s3_bucket.tfstate.id
}

output "github_actions_role_arn" {
  description = "ARN of the IAM Role assumed by GitHub Actions. Set as GitHub repo secret AWS_ROLE_ARN."
  value       = aws_iam_role.github_actions.arn
}

output "github_oidc_provider_arn" {
  description = "ARN of the GitHub OIDC identity provider."
  value       = aws_iam_openid_connect_provider.github.arn
}
