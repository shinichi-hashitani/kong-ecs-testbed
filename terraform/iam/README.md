# IAM 権限定義

`terraform-execution-policy.json` は、本リポジトリの Terraform を実行する **IAM ユーザー**（`aws configure --profile kong-testbed` で登録した Access Key の所有ユーザー）に付与する最小権限の参考ポリシーです。

## 設計方針

- **リソース絞り込み**: 可能な限り `kong-ecs-testbed-*` プレフィックスにスコープ。広範囲が必要なもの（`ec2:*`、`ecs:*` の Describe 系等）は `Resource: "*"` のままだが、Action は最小限。
- **iam:PassRole の対象**: ECS Task Execution Role / Task Role はすべて `kong-ecs-testbed-*` 命名に統一。これにより他リソースへの PassRole は許可しない。
- **Secrets Manager**: Konnect の cluster cert/key を保管する用途で `kong-ecs-testbed/*` 名前空間のみ許可。

## ポリシーの利用方法

本ポリシーは ~4.9KB あり、IAM ユーザー inline policy の 2048 バイト上限を超えるため、**Customer Managed Policy** として作成してから IAM ユーザーに attach してください（6144 バイト枠、現状 80% 使用）。

### 初回作成（0-setup.md Step 1-2）

```bash
# (1) 管理ポリシーを作成
aws iam create-policy \
  --policy-name kong-ecs-testbed-terraform \
  --policy-document file://terraform-execution-policy.json \
  --profile kong-testbed
# → 出力された Policy.Arn を控える

# (2) IAM ユーザーに attach
aws iam attach-user-policy \
  --user-name <terraform を実行する IAM ユーザー名> \
  --policy-arn arn:aws:iam::<account-id>:policy/kong-ecs-testbed-terraform \
  --profile kong-testbed

# (3) 確認
aws iam list-attached-user-policies \
  --user-name <terraform を実行する IAM ユーザー名> \
  --profile kong-testbed
```

### 既存ポリシーの更新（GitOps 移行時など）

**`terraform` ユーザは自分のポリシーを更新できない**（権限昇格防止のため `iam:CreatePolicyVersion` を含めていない）。AWS コンソールから IAM Policy エディタで JSON を貼り直して新 version を default にする。

1. AWS コンソール → IAM → Policies → `kong-ecs-testbed-terraform`
2. **Edit** → **JSON** タブで本リポジトリの最新 [terraform-execution-policy.json](terraform-execution-policy.json) で全文置換
3. **Next** → **Save changes**（最大 5 version まで保持。古い version は IAM コンソールで Delete 可）

> 💡 個人アカウントなら AdministratorAccess でも実害は小さいが、本ポリシーで十分動くので最小権限を推奨。
> ⚠️ `aws iam put-user-policy`（inline 用）はサイズ上限 2048 バイトに引っかかるので使わないこと。

## 確認方法

ポリシー付与後、以下が成功すれば最低限の動作確認 OK:

```bash
aws ec2 describe-vpcs --profile "$AWS_PROFILE" --region "$AWS_REGION"
aws ecs list-clusters --profile "$AWS_PROFILE" --region "$AWS_REGION"
aws elbv2 describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

## 注意

- 検証用想定の権限定義です。本番環境では Resource ARN をさらに絞り込み、Condition で `aws:RequestTag` 等の条件を追加してください。
- Konnect 側の操作は AWS IAM とは無関係（Konnect PAT で認証）です。
- Access Key / Secret は `~/.aws/credentials` のみに置き、リポジトリやメモファイルに貼らないこと。
