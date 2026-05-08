# 99-destroy.md — テスト環境の全抹消

[0-setup.md](0-setup.md) / [1-gitops.md](1-gitops.md) で構築したテストベッドを **全抹消** する手順。AWS リソース・Konnect Control Plane・GitHub の Secret/Variable・ローカル設定の全てを順番に削除する。再構築する場合は 0-setup.md からやり直す前提。

> ⚠️ 全削除のため取り消し不可。本シナリオを最後まで実行すると、Konnect 上の API 設定 / DP 接続 / Terraform state / IAM ユーザまで消える。途中で切り上げる場合は、削除した分だけ部分的に再構築する必要がある。

## 削除対象と依存関係

```
[deck/Konnect 設定]  Service / Route / Plugin / Consumer
        ▲ (terraform/konnect destroy で CP ごと消える)
        │
[terraform/aws]      ECS / ALB / VPC / SG / IAM Roles / Secrets / Cloud Map / CWLogs
        │              ※ data.terraform_remote_state.konnect で konnect 出力を読むため、aws を先に destroy
        ▼
[terraform/konnect]  Konnect CP / DP client cert (cascade で deck 設定も消える)
        │
        ▼
[terraform/bootstrap] S3 bucket (tfstate) / OIDC Provider / IAM Role (GH Actions)
        │              ※ S3 は versioning + force_destroy=false。事前に空にする必要あり
        ▼
[手動]              Customer Managed Policy / IAM user `terraform` / GitHub Secrets-Variables / Konnect PAT / ローカル .env
```

## 前提

- ローカルマシンに `terraform/bootstrap/terraform.tfstate` が残っている（bootstrap の state は意図的に local 保持）
- `aws_profile=kong-testbed` の Access Key がまだ有効（[1-gitops.md](1-gitops.md) 完了後もローカル運用は残っている前提）
- `.env` が手元にあり `set -a; source .env; set +a` で読める
- `terraform/aws/terraform.tfvars` がある（destroy 時にも `allowed_cidrs` の入力が必要。無ければ `-var allowed_cidrs='[]'` で代用可）
- IAM Customer Managed Policy / IAM user の削除には **管理者権限を持つ別ユーザ** が必要（`terraform` ユーザは自身に attach されたポリシーを delete できない）

---

## 手順

### Step 1. terraform/aws を destroy（ローカル実行）

GitOps ワークフローは destroy を流さない（plan/apply のみ）。destroy はローカルから手動で行う。

```bash
cd terraform/aws
set -a; source ../../.env; set +a   # AWS_PROFILE, KONNECT_* を読む

BUCKET=$(cd ../bootstrap && terraform output -raw state_bucket_name)

terraform init -reconfigure \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="key=aws/terraform.tfstate" \
  -backend-config="region=ap-northeast-1" \
  -backend-config="use_lockfile=true"

terraform destroy -var-file=terraform.tfvars
# プロンプトで `yes`
```

期待される削除リソース（順序は terraform が解決）:
- `aws_ecs_service.kong_dp` / `aws_ecs_service.httpbin`
- `aws_ecs_task_definition.kong_dp` / `aws_ecs_task_definition.httpbin`（最新 revision のみ。旧 revision は INACTIVE 状態で残るが課金には影響しない）
- `aws_ecs_cluster.this`
- `aws_lb_listener_rule` / `aws_lb_listener` / `aws_lb_target_group` / `aws_lb`
- `aws_security_group` (alb / dp / httpbin)
- `aws_secretsmanager_secret*` (cert / key) — `recovery_window_in_days=0` なので即時削除
- `aws_iam_role` (task / task_execution) と attach 済みポリシー
- `aws_cloudwatch_log_group` (kong-dp / httpbin)
- `aws_service_discovery_*` / `aws_route53_zone`（Cloud Map private DNS namespace）
- `aws_subnet` / `aws_internet_gateway` / `aws_route_table*` / `aws_vpc.this`

> ⚠️ Task Definition の **旧 revision** は terraform destroy では消えない（terraform は最新 revision のみ管理）。気になる場合は `aws ecs list-task-definitions --status INACTIVE --family-prefix kong-ecs-testbed` で確認の上、`aws ecs deregister-task-definition` を必要数回す（残しても無料）。

> ✅ Step 1 完了条件:
> - `terraform destroy` が `Destroy complete!` で終了
> - AWS コンソール → ECS / VPC / ALB / Secrets Manager / CloudWatch Logs に `kong-ecs-testbed-*` リソースが残っていない

---

### Step 2. terraform/konnect を destroy（ローカル実行）

Konnect CP を削除すると、配下の Service / Route / Plugin / Consumer / DP node が全て **cascade で削除** される。deck で個別削除する必要はない。

```bash
cd ../konnect
set -a; source ../../.env; set +a

BUCKET=$(cd ../bootstrap && terraform output -raw state_bucket_name)
export TF_VAR_konnect_pat="$KONNECT_PAT"

terraform init -reconfigure \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="key=konnect/terraform.tfstate" \
  -backend-config="region=ap-northeast-1" \
  -backend-config="use_lockfile=true"

terraform destroy
```

> 💡 Step 1 で DP タスクは既に止まっているため、Konnect 側で `Disconnected` 状態の DP node が残っていることがある。CP destroy で一緒に消えるので無視してよい。

> ✅ Step 2 完了条件:
> - `terraform destroy` が `Destroy complete!` で終了
> - Konnect コンソール → Gateway Manager で `kong-ecs-testbed-cp` が一覧から消えている

---

### Step 3. tfstate バケットを空にして bootstrap を destroy

bootstrap の `aws_s3_bucket.tfstate` は `force_destroy=false` かつ versioning 有効。Step 1/2 で残った state file（最新版）と過去 version / delete marker をすべて削除しないと `terraform destroy` が `BucketNotEmpty` で失敗する。

#### 3-1. S3 バケット内の全オブジェクトバージョンを削除

```bash
cd ../bootstrap
set -a; source ../../.env; set +a

BUCKET=$(terraform output -raw state_bucket_name)
echo "Target bucket: $BUCKET"

# 全 version を一括削除
aws s3api list-object-versions --bucket "$BUCKET" \
  --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
  --output json > /tmp/s3-versions.json
if [ "$(jq -r '.Objects // [] | length' /tmp/s3-versions.json)" -gt 0 ]; then
  aws s3api delete-objects --bucket "$BUCKET" --delete file:///tmp/s3-versions.json
fi

# 全 delete marker を削除
aws s3api list-object-versions --bucket "$BUCKET" \
  --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
  --output json > /tmp/s3-markers.json
if [ "$(jq -r '.Objects // [] | length' /tmp/s3-markers.json)" -gt 0 ]; then
  aws s3api delete-objects --bucket "$BUCKET" --delete file:///tmp/s3-markers.json
fi

# 確認: バケット内が空であること
aws s3api list-object-versions --bucket "$BUCKET" --output json | jq '{versions: (.Versions // [] | length), markers: (.DeleteMarkers // [] | length)}'
# => {"versions": 0, "markers": 0}
```

#### 3-2. bootstrap を destroy

```bash
terraform destroy
```

期待される削除リソース:
- `aws_s3_bucket.tfstate` および関連 (versioning / encryption / public_access_block 設定)
- `aws_iam_openid_connect_provider.github`
- `aws_iam_role.github_actions` と attach 済みポリシー / inline policy

> 💡 ここで AWS CLI / Terraform が `tflock` ファイル取得失敗を返す場合、3-1 で `<key>.tflock` も含めて削除されているか確認する（list 結果で 0 になっていれば OK）。

> ✅ Step 3 完了条件:
> - `terraform destroy` が `Destroy complete!` で終了
> - AWS コンソールで S3 / OIDC Provider / IAM Role `kong-ecs-testbed-github-actions` が無い

---

### Step 4. 手動クリーンアップ

ここまでで Terraform で作ったものは全て消えた。残りは管理者権限が要る IAM 関連と、外部システム（GitHub / Konnect）側の片付け。

#### 4-1. Customer Managed Policy `kong-ecs-testbed-terraform` を削除（管理者で実施）

`terraform` ユーザは自身に attach されたポリシーを削除できないため、**個人アカウントの管理者ユーザ** で実施する。

```bash
# 管理者プロファイル（仮に admin profile 名）で
aws iam detach-user-policy \
  --user-name terraform \
  --policy-arn arn:aws:iam::<account-id>:policy/kong-ecs-testbed-terraform \
  --profile <admin-profile>

# Policy のすべての version を削除（既定 version は最後に削除可能）
aws iam list-policy-versions \
  --policy-arn arn:aws:iam::<account-id>:policy/kong-ecs-testbed-terraform \
  --profile <admin-profile>
# 出力された IsDefaultVersion=false の VersionId を全て delete
aws iam delete-policy-version \
  --policy-arn arn:aws:iam::<account-id>:policy/kong-ecs-testbed-terraform \
  --version-id <vN> --profile <admin-profile>
# 最後に policy 本体を削除
aws iam delete-policy \
  --policy-arn arn:aws:iam::<account-id>:policy/kong-ecs-testbed-terraform \
  --profile <admin-profile>
```

> 💡 IAM コンソール（admin ユーザでログイン）→ Policies → 当該 policy → Detach + Delete でも同じ操作が可能。

#### 4-2. IAM user `terraform` を削除（管理者で実施）

```bash
ADMIN=<admin-profile>

# Access Key を deactivate + 削除
aws iam list-access-keys --user-name terraform --profile $ADMIN
aws iam update-access-key --user-name terraform --access-key-id <AKIA...> --status Inactive --profile $ADMIN
aws iam delete-access-key --user-name terraform --access-key-id <AKIA...> --profile $ADMIN

# 残った policy を全て detach（4-1 で kong-ecs-testbed-terraform は detach 済み）
aws iam list-attached-user-policies --user-name terraform --profile $ADMIN

# user 削除
aws iam delete-user --user-name terraform --profile $ADMIN
```

> 💡 再度 0-setup.md からやり直す予定があるなら、Customer Managed Policy と IAM user は **残しておく** と再構築が早い。Step 4-1 / 4-2 はスキップして、ローカルの `~/.aws/credentials` の `[kong-testbed]` セクションだけ残せば良い。

#### 4-3. GitHub repo の Secrets / Variables を削除

```bash
unset GITHUB_TOKEN

gh secret delete AWS_ROLE_ARN
gh secret delete KONNECT_PAT
gh secret delete DECK_API_KEY
gh secret delete ALLOWED_CIDRS

gh variable delete TF_STATE_BUCKET
gh variable delete KONNECT_SERVER_URL
gh variable delete KONNECT_CP_NAME
```

> 💡 リポジトリ自体を削除する場合は `gh repo delete <owner>/kong-ecs-testbed --yes` を別途実行（取り消し不可）。

#### 4-4. Konnect Personal Access Token (PAT) を削除

Konnect コンソール → 右上アバター → **Personal Access Tokens** → 該当 PAT (`kpat_...`) を **Revoke**。
（PAT を他用途で使い回している場合はそのまま）

#### 4-5. ローカルファイルのクリーンアップ

```bash
cd <repo-root>

# 機密情報を含むファイル
rm -f .env
rm -f terraform/aws/terraform.tfvars
rm -f terraform/bootstrap/terraform.tfvars

# Terraform の作業ファイル（任意。残してもセキュリティリスクは少ない）
rm -rf terraform/aws/.terraform terraform/aws/.terraform.lock.hcl
rm -rf terraform/konnect/.terraform terraform/konnect/.terraform.lock.hcl
rm -rf terraform/bootstrap/.terraform

# bootstrap の local state（destroy で空に近い状態だがファイルは残る）
rm -f terraform/bootstrap/terraform.tfstate terraform/bootstrap/terraform.tfstate.backup
```

> 💡 AWS profile (`~/.aws/credentials` の `[kong-testbed]` セクション) は他用途と無関係に独立しているので残しても問題ないが、不要なら `~/.aws/credentials` を編集して該当セクションを削除。

---

### Step 5. 抹消完了の確認

| 確認項目 | コマンド / 操作 | 期待 |
| --- | --- | --- |
| ECS リソース | `aws ecs list-clusters` | `kong-ecs-testbed-cluster` が無い |
| ALB | `aws elbv2 describe-load-balancers --query 'LoadBalancers[?contains(LoadBalancerName,\`kong-ecs-testbed\`)]'` | 空配列 |
| VPC | `aws ec2 describe-vpcs --filters Name=tag:Name,Values=kong-ecs-testbed-vpc` | 空 |
| S3 | `aws s3api list-buckets --query 'Buckets[?contains(Name,\`kong-ecs-testbed-tfstate\`)]'` | 空配列 |
| IAM Role | `aws iam list-roles --query 'Roles[?contains(RoleName,\`kong-ecs-testbed\`)]'` | 空配列 |
| OIDC Provider | `aws iam list-open-id-connect-providers` | `token.actions.githubusercontent.com` が他 repo 用途で残っていなければ無し |
| Konnect CP | Konnect コンソール → Gateway Manager | `kong-ecs-testbed-cp` 無し |
| GitHub Secrets | `gh secret list` | 該当 4 件無し |
| GitHub Variables | `gh variable list` | 該当 3 件無し |
| ローカル `.env` | `ls .env` | `No such file` |

---

## トラブルシュート

| 症状 | 原因 / 対処 |
| --- | --- |
| `terraform destroy` で `Error: AccessDenied` | Step 4 を先にやって `terraform` ユーザのポリシーが detach 済み、または policy が古い。`kong-ecs-testbed-terraform` を attach した状態で再実行 |
| bootstrap destroy で `BucketNotEmpty` | Step 3-1 が未実施 / 漏れ。`aws s3api list-object-versions --bucket $BUCKET` で残骸を確認、削除してから retry |
| terraform/aws destroy で `Cannot remove subnet ... in use` | ALB / ECS タスクの ENI が残っている。`aws ec2 describe-network-interfaces --filters Name=vpc-id,Values=<vpc-id>` で残骸 ENI を `delete-network-interface`、その後 retry |
| terraform/konnect destroy で 401 | `TF_VAR_konnect_pat` または `.env` の `KONNECT_PAT` が空 / 期限切れ。Konnect で再発行して export |
| `terraform destroy` が tflock 取得で待つ | 過去の lock (`<key>.tflock`) が S3 に残骸として残っている。S3 コンソール / CLI で当該オブジェクトを削除 |
| `aws iam delete-policy` で `DeleteConflict` | Policy が他 entity に attach 済み。`aws iam list-entities-for-policy --policy-arn ...` で全 detach した後に delete |

## 注意事項

- **再構築する場合**: 0-setup.md → 1-gitops.md の順で構築。Step 4-1 / 4-2 をスキップして IAM user / Customer Managed Policy を残しておけば、再構築時の手数が減る
- **部分的な削除は推奨しない**: `terraform destroy -target=...` は依存関係を壊しやすい。本シナリオは「全削除」前提
- **課金が止まるタイミング**: ECS タスクは Step 1 destroy 中に停止して以降課金されない。NAT Gateway は本テストベッドでは使っていない（public subnet only）。ALB は Step 1 で削除（時間課金）。Secrets Manager / S3 は微少課金が destroy 完了まで残る
- **Konnect 側の課金**: Konnect Free Plan 内であれば CP 削除で課金は発生しない。有償プランで CP を作っていた場合は契約条件を確認すること
