# 2-kong-upgrade.md — Kong 3.13 → 3.14 アップグレード

[1-gitops.md](1-gitops.md) で構築した GitHub Actions パイプライン経由で、ECS 上の Kong Gateway DP を `3.13` から `3.14` にアップグレードする。Konnect Hybrid mode では Control Plane は Konnect 側 (SaaS) で常に最新が当たっているため、本シナリオで触るのは **Data Plane の container image だけ**。実際の作業は `terraform/aws/variables.tf` の `kong_dp_image` を 1 行書き換えて PR を出すだけで、ECS の rolling update が新タスクを起動して旧タスクを置き換える。

## アーキテクチャの動き

```
PR open                          PR merge to main
  │                                │
  ▼                                ▼
terraform-aws.yml: plan      terraform-aws.yml: apply
  │                                │
  └─ Task Definition の         └─ aws_ecs_task_definition.kong_dp が
     image 変更を diff として      新 revision で作られ、aws_ecs_service.kong_dp
     PR に貼る                    が新 revision を参照
                                   │
                                   ▼
                              ECS rolling update
                                3.13 task ─┐
                                           ├─▶ 3.14 task (healthy)
                                3.13 task  ─┘   ALB に register, 旧 task は drain
```

> 💡 Konnect (CP) と Kong DP のバージョン互換は **CP ≥ DP の minor 1 つ差まで**（Konnect は常に最新 GA の major.minor をサポート）。3.13 → 3.14 は同 major 内の minor バンプなので問題ない。major またぎ（例: 3.x → 4.x）は本シナリオの対象外。

## 前提

- [1-gitops.md](1-gitops.md) を完了している（GitHub Actions の terraform-aws ワークフローが PR で plan / main で apply を走らせる構成）
- 現状 ECS で `kong/kong-gateway:3.13` が稼働し、`curl http://<alb>/httpbin/get` が 200 を返す
- ローカルから `set -a; source .env; set +a` で `AWS_PROFILE=kong-testbed` が読める（ロールバック確認用）
- [Kong Gateway 3.14 Release Notes](https://docs.konghq.com/gateway/changelog/) を確認し、利用中のプラグインや設定に breaking change が無いことを確認済み

---

## 手順

### Step 1. アップグレード対象のブランチを作成

```bash
git checkout main
git pull
git checkout -b chore/kong-3.14
```

### Step 2. `kong_dp_image` を 3.14 に更新

[terraform/aws/variables.tf](terraform/aws/variables.tf) の `kong_dp_image` の default を変更する:

```diff
 variable "kong_dp_image" {
   description = "Container image for Kong Gateway DP."
   type        = string
-  default     = "kong/kong-gateway:3.13"
+  default     = "kong/kong-gateway:3.14"
 }
```

> 💡 tag を固定したい場合は `kong/kong-gateway:3.14.0.0` のようにパッチまで指定する。本テストベッドでは minor tag (3.14) で常に最新パッチを掴む方針。

### Step 3. PR を作成して plan を確認

```bash
git add terraform/aws/variables.tf
git commit -m "Bump Kong DP image to 3.14"
git push -u origin chore/kong-3.14

gh pr create --base main \
  --title "Bump Kong DP image to 3.14" \
  --body "Upgrade Kong Gateway DP from 3.13 to 3.14 via GitOps. Triggers ECS rolling update of kong-ecs-testbed-kong-dp service."
```

GitHub Actions の `Terraform AWS / plan` job が走り、PR に plan diff がコメントされる。期待される差分は **概ね 1 リソース change のみ**:

```hcl
  # aws_ecs_task_definition.kong_dp must be replaced
  ~ resource "aws_ecs_task_definition" "kong_dp" {
        ~ container_definitions    = jsonencode([
            ~ {
                ~ image = "kong/kong-gateway:3.13" -> "kong/kong-gateway:3.14"
              # ...
            },
        ])
        ~ revision                 = 1 -> (known after apply)
      # ...
    }

  # aws_ecs_service.kong_dp will be updated in-place
  ~ resource "aws_ecs_service" "kong_dp" {
      ~ task_definition = "...:1" -> (known after apply)
    }
```

> ⚠️ image 以外の差分（環境変数 / secrets / port 等）が含まれていたら **マージしない**。何か別の変更が混入している。

### Step 4. main にマージ

PR レビューが OK なら squash merge:

```bash
gh pr merge --squash --delete-branch
```

main 側で `Terraform AWS / apply` job が走り、新しい Task Definition revision が作られて ECS service が rolling update を開始する。

### Step 5. ECS rolling update を監視

```bash
set -a; source .env; set +a

# 直近のデプロイ状況
aws ecs describe-services \
  --cluster kong-ecs-testbed-cluster \
  --services kong-ecs-testbed-kong-dp \
  --query 'services[0].deployments[*].{status:status,taskDef:taskDefinition,desired:desiredCount,running:runningCount,pending:pendingCount}' \
  --output table

# Task Definition の最新 revision
aws ecs describe-task-definition \
  --task-definition kong-ecs-testbed-kong-dp \
  --query 'taskDefinition.{revision:revision,image:containerDefinitions[0].image}'
```

- `deployments` に `PRIMARY`（新 revision）と `ACTIVE`（旧 revision）が並び、`PRIMARY` の `runningCount` が `desiredCount` に達して `ACTIVE` が消えたら完了
- ALB Target Group のヘルスチェック (`/status/ready`、port 8100) で新タスクが 2 回連続 healthy になるまで `ACTIVE` 側はトラフィックを受け続けるため、proxy 経路は途切れない想定

> 💡 [terraform/aws/kong_dp.tf](terraform/aws/kong_dp.tf) の `aws_ecs_service.kong_dp` は `deployment_minimum_healthy_percent = 0` / `deployment_maximum_percent = 200` で設定されている。`desired_count = 1` のため、本テストベッドでは「新タスクが healthy になるまで旧タスクが動く → 新タスク healthy 後に旧タスクを停止」という挙動になる（厳密にはほぼ無停止だが、ALB の登録/解除タイミングで数秒のレイテンシ揺れはありうる）。

### Step 6. 動作確認

```bash
# (1) Proxy 経路の疎通
ALB_DNS=$(cd terraform/aws && terraform output -raw alb_dns_name)
curl -i -H "apikey: $DECK_API_KEY" "http://${ALB_DNS}/httpbin/get"   # 200

# (2) DP の version を直接問い合わせ（ECS Exec → kong version）
TASK_ARN=$(aws ecs list-tasks \
  --cluster kong-ecs-testbed-cluster \
  --service-name kong-ecs-testbed-kong-dp \
  --query 'taskArns[0]' --output text)

aws ecs execute-command \
  --cluster kong-ecs-testbed-cluster \
  --task "$TASK_ARN" \
  --container kong \
  --interactive \
  --command "kong version"
# => Kong Gateway 3.14.x.x ...

# (3) Konnect 側の DP 認識
# Konnect コンソール → Gateway Manager → kong-ecs-testbed-cp → Data Plane Nodes
# version カラムが 3.14.x.x になっていることを確認
```

> ✅ Step 6 完了条件:
> - `curl /httpbin/get` が 200
> - `kong version` の出力が `3.14.x.x`
> - Konnect の Data Plane Nodes 一覧で同じ version が見える

---

## ロールバック

問題が見つかった場合は、同じ GitOps の流れで戻す。**手元で `terraform apply` する必要は無い**。

### A. 直前のマージを revert

```bash
git checkout main
git pull
git revert <merge-commit-sha> -m 1   # squash merge のときは -m 1 不要、commit に直接 revert
git push origin main
```

main への push で apply が走り、`kong_dp_image` が `3.13` に戻った Task Definition で rolling update がかかる。

### B. 明示的に PR を出す

revert ではなく「3.14 → 3.13 に戻す」差分を明示的に PR にしたいケース:

```bash
git checkout -b chore/kong-3.13-rollback
# variables.tf の default を "kong/kong-gateway:3.13" に戻す
git commit -am "Revert Kong DP image to 3.13"
gh pr create --base main --title "Rollback Kong DP image to 3.13" --body "Roll back due to <reason>"
```

> 💡 ECS は同じ image を指す Task Definition でも revision は新規に作られる（container_definitions の jsonencode 比較で差分判定）。ロールバックでも rolling update は発生する。

---

## 注意事項

- **CP-DP version skew**: Konnect は CP の version を常に最新 GA で管理しているため、DP 側を古いまま放置しても CP 側で先に新機能が入ることがある。逆方向（DP > CP）は Konnect では起こらない（CP は常に最先端）
- **DB-less / Konnect mode のみ**: 本テストベッドは `KONG_DATABASE=off` + `KONG_KONNECT_MODE=on` で動いているため、Postgres を使うアップグレードシナリオ（`kong migrations up` 等）は対象外。Self-managed CP のアップグレードは本シナリオに含まない
- **plugin 互換**: 標準プラグイン (`key-auth` 等) のみ使っているうちは minor バンプで壊れにくいが、custom plugin / Lua スクリプトを足した場合は 3.14 release notes の breaking changes セクションを必ず確認すること
- **deck/kong.yaml は無関係**: 本シナリオは DP の image を変えるだけなので、Konnect CP 側の Service / Route / Plugin 設定 ([deck/kong.yaml](deck/kong.yaml)) は触らない。ALB → Kong DP → httpbin の経路と Konnect 側の設定は不変
- **同時実行**: workflow の `concurrency: terraform-aws-${{ github.ref }}` で main の apply は直列化されるが、ローカル `terraform apply` を併走させると S3 lock を取り合う。upgrade 中は手元での apply を避ける

## トラブルシュート

| 症状 | 原因 / 対処 |
| --- | --- |
| 新タスクが `unhealthy` で起動と停止を繰り返す | ALB Target Group health check (`/status/ready`) が 200 を返さない。CP との接続失敗の可能性。CloudWatch Logs `/ecs/kong-ecs-testbed/kong-dp` で `[error]` を grep |
| `kong version` が古いまま | rolling update が完了していない。`describe-services` の `deployments` を再確認、または Task Definition の最新 revision を Service が参照しているか確認 |
| Konnect 側で DP が `Disconnected` | cluster cert ([terraform/konnect](terraform/konnect)) が期限切れ、または 3.14 の cluster protocol 互換に何かしらの変更がある可能性。CloudWatch Logs で `cluster:` 行を確認 |
| `terraform plan` の diff が image 以外にも出る | 直近の他 PR の影響、または provider version 差。**先にそちらを解決してから upgrade PR を出す** |
