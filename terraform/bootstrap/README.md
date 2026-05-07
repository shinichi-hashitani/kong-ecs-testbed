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
- **`kong-ecs-testbed-terraform` ポリシーが最新版**（OIDC Provider / S3 / DynamoDB の権限を含む）。後述の手順で IAM コンソールから更新する

## 必要な権限の追加

bootstrap は以下のリソースを作るため、`terraform-execution-policy.json` に **3 つの statement を追加済み**（[../iam/terraform-execution-policy.json](../iam/terraform-execution-policy.json) 参照）:

| Sid | 用途 | スコープ |
| --- | --- | --- |
| `IamOidcProviderForGithub` | GitHub Actions OIDC Provider 操作 | account-wide |
| `S3StateBucket` | tfstate バケット (`kong-ecs-testbed-tfstate-*`) のフル管理 | bucket name 限定 |
| `DynamoDBStateLockTable` | lock テーブル (`kong-ecs-testbed-tflocks`) のフル管理 | table name 限定 |

`terraform` ユーザは自身のポリシーを更新できない（権限昇格防止）ため、IAM コンソールから手動更新する:

1. AWS コンソール → IAM → Policies → `kong-ecs-testbed-terraform` を開く
2. **Edit** → JSON タブ → 本リポジトリの最新 [../iam/terraform-execution-policy.json](../iam/terraform-execution-policy.json) で全文置換
3. **Next** → **Save changes**（新しいバージョンが作られ、それが既定になる）

## 実行

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を編集して github_owner を自身の GitHub アカウント名に

set -a; source ../../.env; set +a   # AWS_PROFILE=kong-testbed を読み込む

terraform init
terraform plan
terraform apply
```

apply 完了後、`terraform output` で 4 つの値が表示される。これらを GitHub の repo Secrets / Variables に登録する手順は [1-gitops.md](../../1-gitops.md) 参照。

> 💡 このモジュールの state は意図的に **local 保持** にしている（自身が作る S3 バケットを backend にできない chicken-and-egg のため）。`terraform/bootstrap/terraform.tfstate` は `.gitignore` で除外される。
