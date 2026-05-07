# terraform/aws

AWS 側基盤リソース（VPC / ECS Cluster / ALB / Cloud Map / IAM）と、後続ステップで追加する httpbin・Kong DP の ECS リソース群。

## ファイル分割

| ファイル | 内容 | 追加 Step |
| --- | --- | --- |
| `versions.tf` | terraform / provider バージョン制約 | 3 |
| `providers.tf` | aws provider + default_tags | 3 |
| `variables.tf` | 入力変数 | 3 |
| `locals.tf` | 命名 / 共通タグ | 3 |
| `data.tf` | AZ 情報、`terraform/konnect` の remote_state | 3 |
| `vpc.tf` | VPC / 2 Public Subnet / IGW / RT | 3 |
| `security_groups.tf` | ALB / DP / httpbin の SG | 3 |
| `ecs.tf` | ECS Cluster (Fargate) | 3 |
| `alb.tf` | ALB + 既定 404 Listener | 3 |
| `cloudmap.tf` | Cloud Map 名前空間 (`<project>.local`) | 3 |
| `iam.tf` | Task Execution Role + Task Role (ECS Exec 用 SSM Messages) | 3 |
| `outputs.tf` | 各種出力 | 3 |
| `httpbin.tf` | httpbin Task Def + Service + SD Service | 4 |
| `kong_dp.tf` | Kong DP Task Def + Service + ALB TG/Rule + Secrets | 5 |

## 必須入力

`allowed_cidrs` のみ必須。`terraform.tfvars.example` をコピーして編集。

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を編集: allowed_cidrs に自宅/オフィスの IP/32 を入れる
```

> 💡 `terraform.tfvars` は `.gitignore` 済み。社内 IP を誤って commit しないため。

## 実行手順 (Step 3 まで)

```bash
# プロジェクトルートで .env 読み込み済み + aws configure --profile kong-testbed 済み前提
set -a; source .env; set +a

cd terraform/aws
terraform init
terraform plan
terraform apply
```

`apply` 完了後、`terraform output` で `vpc_id` / `alb_dns_name` 等が表示される。

> ⚠️ Step 3 単独では ALB のターゲットがいないため、`alb_dns_name` にアクセスすると 404 が返る。これは想定動作。
