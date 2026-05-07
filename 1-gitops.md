# 1-gitops.md — 作業の GitOps 化

[0-setup.md](0-setup.md) で構築したテストベッドの運用を **GitHub Actions** 経由に移行する。Access Key を排除し、Terraform の state は S3 + DynamoDB に集約、`terraform plan` は PR 上で確認、`terraform apply` / `deck gateway sync` は main マージで自動実行する構成にする。

> 💡 完了後は `terraform/` / `deck/` への変更は必ず PR 経由で行うこと。手元での `terraform apply` も引き続き可能だが、state が共有される点は意識する。

## アーキテクチャ概要（GitOps 後）

```
┌──────────────────────────────────────────────────────────────────────┐
│ GitHub Repository                                                    │
│  ├─ PR opened       ──▶ workflow: terraform plan / deck diff         │
│  └─ push to main    ──▶ workflow: terraform apply / deck sync        │
└────────────┬──────────────────────────┬──────────────────────────────┘
             │ OIDC (sts.amazonaws.com) │ HTTPS (Konnect PAT)
             ▼                          ▼
┌────────────────────────┐    ┌────────────────────────────────────────┐
│ AWS                    │    │ Kong Konnect                           │
│  IAM Role (assume)     │    │  Control Plane: kong-ecs-testbed-cp    │
│  S3 (tfstate)          │    │                                        │
│  DynamoDB (tflocks)    │    └────────────────────────────────────────┘
│  ECS / ALB / etc.      │
└────────────────────────┘
```

## 構成物

| パス | 用途 |
| --- | --- |
| [terraform/bootstrap/](terraform/bootstrap/) | S3 / DynamoDB / OIDC Provider / IAM Role を作る Terraform。**ローカル一回だけ** apply する |
| [.github/workflows/terraform-aws.yml](.github/workflows/terraform-aws.yml) | `terraform/aws/**` 変更で plan (PR) / apply (main) |
| [.github/workflows/terraform-konnect.yml](.github/workflows/terraform-konnect.yml) | `terraform/konnect/**` 変更で plan (PR) / apply (main) |
| [.github/workflows/deck-sync.yml](.github/workflows/deck-sync.yml) | `deck/**` 変更で diff (PR) / sync (main) |
| `terraform/aws/versions.tf` / `terraform/konnect/versions.tf` | `backend "s3" {}` を追加（partial config、`-backend-config` で値を渡す） |

## 前提

- [0-setup.md](0-setup.md) を Step 1〜7 まで完了している
- ローカルに `aws configure --profile kong-testbed` 済み
- `kong/kong-gateway:3.13` が ECS で稼働中
- このリポジトリが GitHub に push 済みで、admin 権限を持つ

---

## 手順

### Step 1. terraform-execution-policy を更新（IAM コンソール）

bootstrap が必要とする OIDC Provider / S3 / DynamoDB の権限が、もともと 0-setup で適用したポリシーには入っていない。本リポジトリの最新 [terraform-execution-policy.json](terraform/iam/terraform-execution-policy.json) には以下 3 statement が追加済み:

| Sid | スコープ |
| --- | --- |
| `IamOidcProviderForGithub` | `iam:*OpenIDConnect*` (account-wide) |
| `S3StateBucket` | `s3:*` on `kong-ecs-testbed-tfstate-*` |
| `DynamoDBStateLockTable` | `dynamodb:*` on `kong-ecs-testbed-tflocks` |

`terraform` ユーザは自身のポリシーを更新できないため、IAM コンソールで手動更新する:

1. AWS コンソール → IAM → **Policies** → `kong-ecs-testbed-terraform` を開く
2. **Edit** → **JSON** タブ → 本リポジトリの [terraform-execution-policy.json](terraform/iam/terraform-execution-policy.json) で全文置換
3. **Next** → **Save changes**

> ✅ Step 1 完了条件:
> - ポリシーの新しい version が default として有効
> - `aws iam get-policy --policy-arn arn:aws:iam::<account-id>:policy/kong-ecs-testbed-terraform` で `DefaultVersionId` が増えている

### Step 2. Bootstrap を apply（ローカル一回）

#### 2-1. 変数を設定

```bash
cd terraform/bootstrap
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を編集して github_owner を自身の GitHub アカウント名に
```

#### 2-2. 実行

```bash
set -a; source ../../.env; set +a   # AWS_PROFILE=kong-testbed を読み込む
aws sts get-caller-identity         # Arn が user/terraform であることを確認

terraform init
terraform plan
terraform apply
```

> 💡 このモジュールは S3 / DynamoDB / OIDC / IAM Role を作る。state は意図的に **local** に置く（自身が作る S3 を backend にできない chicken-and-egg のため）。`terraform/bootstrap/terraform.tfstate` は gitignore 対象。

#### 2-3. Output の控え

```bash
terraform output
```

以下 4 つを次の Step で GitHub に登録する:

| Terraform output | 登録先 (GitHub) |
| --- | --- |
| `state_bucket_name` | repo Variable `TF_STATE_BUCKET` |
| `state_lock_table_name` | repo Variable `TF_LOCK_TABLE` |
| `github_actions_role_arn` | repo Secret `AWS_ROLE_ARN` |
| `github_oidc_provider_arn` | （登録不要、確認用） |

> ✅ Step 2 完了条件:
> - `terraform output state_bucket_name` が `kong-ecs-testbed-tfstate-<account-id>` を返す
> - AWS コンソールで S3 / DynamoDB / OIDC Provider / IAM Role が見える

---

### Step 3. GitHub repo の Secrets / Variables 設定

GitHub UI: **Settings → Secrets and variables → Actions** で登録する。

#### 2-1. Variables（公開設定。読みやすさのため）

| Name | 値 |
| --- | --- |
| `TF_STATE_BUCKET` | Step 2-3 の `state_bucket_name` |
| `TF_LOCK_TABLE` | Step 2-3 の `state_lock_table_name` |
| `KONNECT_SERVER_URL` | `https://us.api.konghq.com` |
| `KONNECT_CP_NAME` | `kong-ecs-testbed-cp` |

#### 2-2. Secrets（機密。logs にマスキングされる）

| Name | 値 |
| --- | --- |
| `AWS_ROLE_ARN` | Step 2-3 の `github_actions_role_arn` |
| `KONNECT_PAT` | Konnect で発行済みの PAT (`kpat_...`)。0-setup.md 2-1 と同じ値 |
| `DECK_API_KEY` | テスト用 API キー。0-setup.md 6-1 で `openssl rand -hex 24` 生成した値 |
| `ALLOWED_CIDRS` | HCL list 形式の文字列。例: `["203.0.113.10/32"]`（中括弧・引用符込み） |

> ⚠️ `ALLOWED_CIDRS` は terraform variable として渡すため **HCL list literal** で保存する。`["1.2.3.4/32","5.6.7.8/32"]` のように JSON 風だが内部はダブルクオート必須。
> 💡 `gh` CLI でも登録可能:
> ```bash
> gh variable set TF_STATE_BUCKET --body "kong-ecs-testbed-tfstate-901355306350"
> gh secret   set ALLOWED_CIDRS    --body '["203.0.113.10/32"]'
> ```

> ✅ Step 3 完了条件:
> - **Settings → Secrets and variables → Actions** に上記 4 vars + 4 secrets が表示される

---

### Step 4. 既存 local state を S3 に移行

`terraform/aws/versions.tf` / `terraform/konnect/versions.tf` には既に `backend "s3" {}` 空ブロックが入っている。次回 `terraform init` で backend 切替が検知されるので、`-migrate-state` フラグで既存の local state を S3 に転送する。

#### 3-1. terraform/konnect の state 移行

```bash
cd terraform/konnect
terraform init -migrate-state \
  -backend-config="bucket=$(cd ../bootstrap && terraform output -raw state_bucket_name)" \
  -backend-config="key=konnect/terraform.tfstate" \
  -backend-config="region=ap-northeast-1" \
  -backend-config="dynamodb_table=$(cd ../bootstrap && terraform output -raw state_lock_table_name)"
# プロンプトで `yes` を入力（既存 state を S3 に移すか）
```

完了したら local の `terraform.tfstate` / `terraform.tfstate.backup` が空に戻る（または `terraform.tfstate.backup` に旧 state が残る）。

```bash
terraform plan   # No changes になることを確認
```

#### 3-2. terraform/aws の state 移行

```bash
cd ../aws
terraform init -migrate-state \
  -backend-config="bucket=$(cd ../bootstrap && terraform output -raw state_bucket_name)" \
  -backend-config="key=aws/terraform.tfstate" \
  -backend-config="region=ap-northeast-1" \
  -backend-config="dynamodb_table=$(cd ../bootstrap && terraform output -raw state_lock_table_name)"
# プロンプトで `yes`
```

```bash
terraform plan -var-file=terraform.tfvars   # No changes
```

> 💡 移行後、ローカルの `terraform.tfstate` ファイルは中身が空（backend 設定のみ）になる。間違って削除しても S3 にあるので問題ない。
> ⚠️ 移行作業中は他のメンバー（または CI）が同時 apply しないよう注意。

> ✅ Step 4 完了条件:
> - `terraform/konnect/` / `terraform/aws/` で `terraform plan` が `No changes` を返す
> - S3 バケットに `konnect/terraform.tfstate` / `aws/terraform.tfstate` の 2 オブジェクトがある

---

### Step 5. 動作確認（試し PR で plan を回す）

#### 4-1. 任意の no-op 変更を加えてブランチ push

```bash
git checkout -b test/gitops-pipeline
echo "" >> terraform/aws/locals.tf   # 空行追加だけ
git add terraform/aws/locals.tf
git commit -m "test: trigger gitops plan"
git push -u origin test/gitops-pipeline
```

#### 4-2. PR を作成

```bash
gh pr create --base main --title "test: gitops pipeline" --body "Verifying terraform-aws workflow plan job."
```

#### 4-3. Actions を確認

GitHub UI → **Actions** タブ → `Terraform AWS` workflow が起動し、`plan` job が `Success` で終わっていれば OK。PR にコメントで `### Terraform AWS plan` 付きの diff が貼られる（`No changes` 想定）。

#### 4-4. テスト PR を破棄

```bash
gh pr close test/gitops-pipeline --delete-branch
git checkout main
git branch -D test/gitops-pipeline
```

> ✅ Step 5 完了条件:
> - `Terraform AWS / plan` workflow が `Success`
> - PR コメントに plan が貼られている（`No changes` または意図した差分のみ）

---

### Step 6. ローカル apply の継続使用について

bootstrap 後もローカルでの `terraform apply` は引き続き可能（state は S3 で共有）:

```bash
cd terraform/aws
terraform plan
terraform apply
```

ただし以下のルールを守る:
- **同時 apply は不可**（DynamoDB lock により競合する）
- **CI が apply 中はローカルから打たない**（ロック取得待ちにはなるが、混乱の元）
- **本番運用相当のコミットは PR 経由のみ** にし、ローカル apply はトラブル切り分け時の救済手段として残す

---

## トラブルシュート

| 症状 | 原因 / 対処 |
| --- | --- |
| `Backend initialization required` | `terraform init -migrate-state -backend-config="..."` を再実行 |
| Workflow が `preflight: skipped` で止まる | `vars.TF_STATE_BUCKET` / `secrets.AWS_ROLE_ARN` 等が空。Step 3 を見直す |
| `Error: AccessDenied` on `s3:GetObject` | IAM Role に state-backend inline policy が attach されていない。bootstrap apply からやり直し |
| `Error: NoCredentialProviders` | `id-token: write` 権限が workflow の `permissions:` に無い、または OIDC trust の `sub` 条件が `repo:OWNER/REPO:*` と合っていない。bootstrap の `var.github_owner` を確認 |
| deck workflow が 401 | `secrets.DECK_API_KEY` 未設定、または値が空。0-setup.md 6-1 で控えた値で再登録 |
| Plan job で `Error parsing variable allowed_cidrs` | `secrets.ALLOWED_CIDRS` の文字列が HCL list literal でない。`["1.2.3.4/32"]` の形にする |

## 注意事項

- **bootstrap の destroy は最後**: 他の terraform/* を destroy した後でないと、state が S3 に残ったまま bucket を削除できない
- **OIDC trust 条件**: `bootstrap/main.tf` の `github_sub_pattern` は `repo:OWNER/REPO:*` で、当該 repo の **全ブランチ・全 PR** で role assume を許可している。本番では `:ref:refs/heads/main` 等で絞ること
- **Konnect PAT のローテーション**: PAT 期限が来たら、Konnect コンソールで新 PAT を発行 → `gh secret set KONNECT_PAT --body "kpat_..."` で更新
- **DECK_API_KEY のローテーション**: `openssl rand -hex 24` で再生成 → `gh secret set DECK_API_KEY` で更新 → main に対して `deck/kong.yaml` の dummy 変更を含む PR を出すと sync workflow が新キーで credential 上書き
