###############################################################################
# Bootstrap (Step 1 of GitOps)
#
# Provisions the prerequisites for running terraform/aws & terraform/konnect
# from GitHub Actions:
#   - S3 bucket  : remote state backend
#   - DynamoDB   : state lock table
#   - OIDC       : GitHub Actions OIDC identity provider
#   - IAM Role   : assumed by GitHub Actions, attached with the existing
#                  terraform-execution Customer Managed Policy + state backend
#                  inline policy
#
# Run this LOCALLY one time using the same `terraform` IAM user from 0-setup.
# State for *this* module stays local (it's the chicken bootstrapping the egg).
###############################################################################

data "aws_caller_identity" "current" {}

locals {
  account_id            = data.aws_caller_identity.current.account_id
  state_bucket_name     = "${var.project}-tfstate-${local.account_id}"
  state_lock_table_name = "${var.project}-tflocks"
  oidc_role_name        = "${var.project}-github-actions"
  github_sub_pattern    = "repo:${var.github_owner}/${var.github_repo}:*"
}

###############################################################################
# S3 bucket: Terraform remote state
###############################################################################
resource "aws_s3_bucket" "tfstate" {
  bucket        = local.state_bucket_name
  force_destroy = false
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

###############################################################################
# DynamoDB: Terraform state lock table
###############################################################################
resource "aws_dynamodb_table" "tflocks" {
  name         = local.state_lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

###############################################################################
# GitHub Actions OIDC provider
###############################################################################
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

###############################################################################
# IAM Role: assumed by GitHub Actions
###############################################################################
data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_sub_pattern]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = local.oidc_role_name
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
  description        = "Assumed by GitHub Actions in ${var.github_owner}/${var.github_repo} for terraform plan/apply and deck sync."
}

# Reuse the Customer Managed Policy created in 0-setup (terraform-execution-policy.json)
data "aws_iam_policy" "terraform_execution" {
  name = var.terraform_policy_name
}

resource "aws_iam_role_policy_attachment" "terraform_execution" {
  role       = aws_iam_role.github_actions.name
  policy_arn = data.aws_iam_policy.terraform_execution.arn
}

# Inline policy: S3 + DynamoDB access for the state backend
data "aws_iam_policy_document" "state_backend" {
  statement {
    sid     = "S3ListStateBucket"
    effect  = "Allow"
    actions = ["s3:ListBucket"]
    resources = [
      aws_s3_bucket.tfstate.arn,
    ]
  }

  statement {
    sid    = "S3StateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [
      "${aws_s3_bucket.tfstate.arn}/*",
    ]
  }

  statement {
    sid    = "DynamoDBStateLocks"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [
      aws_dynamodb_table.tflocks.arn,
    ]
  }
}

resource "aws_iam_role_policy" "state_backend" {
  name   = "state-backend"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.state_backend.json
}
