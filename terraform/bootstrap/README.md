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

- 0-setup.md (Step 1) を完了済み（`aws configure --profile kong-testbed` + Customer Managed Policy `kong-ecs-testbed-terraform` が attach 済み）
- ターミナルで `.env` 読み込み済み（`AWS_PROFILE=kong-testbed`）

## 実行

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を編集して github_owner を自身のアカウント名に

terraform init
terraform plan
terraform apply
```

apply 完了後、`terraform output` で 4 つの値が表示される。これらを GitHub の repo Secrets / Variables に登録する手順は [1-gitops.md](../../1-gitops.md) 参照。

> 💡 このモジュールの state は意図的に **local 保持** にしている（自身が作る S3 バケットを backend にできない chicken-and-egg のため）。`terraform/bootstrap/terraform.tfstate` は `.gitignore` で除外される。
