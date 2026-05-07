# terraform/bootstrap

GitOps（[1-gitops.md](../../1-gitops.md)）の前提となるリソース一式。**ローカルで一度だけ apply** する想定。

## 作成物

| リソース | 用途 |
| --- | --- |
| S3 bucket `<project>-tfstate-<account-id>` | `terraform/aws` / `terraform/konnect` の remote state |
| DynamoDB table `<project>-tflocks` | state lock |
| OIDC Provider `token.actions.githubusercontent.com` | GitHub Actions の OIDC 認可 |
| IAM Role `<project>-github-actions` | GitHub Actions が `AssumeRoleWithWebIdentity` で引き受ける |
| Role attachments | (1) 0-setup で作成済の `kong-ecs-testbed-terraform` ポリシー、(2) state backend 用 inline policy |

## 前提

- 0-setup.md (Step 1) を完了済み（Customer Managed Policy `kong-ecs-testbed-terraform` が `terraform` ユーザに attach 済み）
- **AWS 管理者権限のクレデンシャル** が利用可能（後述）

## 必要な権限

bootstrap は以下の **管理者権限相当のリソース** を作る:

| リソース | 必要権限（terraform-execution-policy には未含有） |
| --- | --- |
| OIDC Identity Provider | `iam:CreateOpenIDConnectProvider` 等 |
| S3 bucket (state)      | `s3:CreateBucket`, `s3:Put*`, `s3:Get*`, `s3:DeleteBucket` |
| DynamoDB table (lock)  | `dynamodb:CreateTable`, `dynamodb:Describe*`, `dynamodb:DeleteTable`, `dynamodb:TagResource` |

`terraform` ユーザの `kong-ecs-testbed-terraform` ポリシーにはこれらが含まれていないため、そのままでは AccessDenied になる。bootstrap は一回限りのセットアップなので、**0-setup.md 1-2 で `aws iam create-policy` を実行した時のクレデンシャル（AdministratorAccess 等）を使う**こと。

利用例:

```bash
# 例: 別プロファイルを使う場合
aws configure --profile kong-testbed-admin
export AWS_PROFILE=kong-testbed-admin

# 例: 環境変数で一時的に渡す場合
export AWS_ACCESS_KEY_ID="AKIA..."
export AWS_SECRET_ACCESS_KEY="..."
export AWS_REGION=ap-northeast-1
```

> 💡 完了後は `unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY` または `unset AWS_PROFILE` で admin 権限から戻し、通常作業は `AWS_PROFILE=kong-testbed` に切り替え直す。

## 実行

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を編集して github_owner を自身のアカウント名に

# admin クレデンシャルが有効になっていることを確認
aws sts get-caller-identity   # Arn が user/<admin> 等になっているはず（user/terraform ではない）

terraform init
terraform plan
terraform apply
```

apply 完了後、`terraform output` で 4 つの値が表示される。これらを GitHub の repo Secrets / Variables に登録する手順は [1-gitops.md](../../1-gitops.md) 参照。

> 💡 このモジュールの state は意図的に **local 保持** にしている（自身が作る S3 バケットを backend にできない chicken-and-egg のため）。`terraform/bootstrap/terraform.tfstate` は `.gitignore` で除外される。
