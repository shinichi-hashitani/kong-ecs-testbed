# 0-setup.md — 初回セットアップ手順

AWS ECS (Fargate) 上に Kong Gateway DP（既定 `3.13`）を立て、Kong Konnect (US Geo) を CP として連携するテスト環境をローカルマシンから手動構築する。Step 1〜7 を順番に実行する。

> 💡 完了後の継続運用は [1-gitops.md](1-gitops.md) で GitHub Actions による GitOps 化に移行する想定。
> 💡 構築済み環境のバージョン更新シナリオは [2-kong-upgrade.md](2-kong-upgrade.md) を参照。

## 手順

### Step 1. AWS / ECS アクセス設定

> **対象**: ローカル開発マシン（macOS）。**個人 AWS アカウントの IAM ユーザー Access Key** を `aws configure` で登録し、東京リージョン (`ap-northeast-1`) で操作する前提（社内 SSO / saml2aws は使わない）。

#### 1-1. ツールのインストール（未導入の場合）

```bash
brew install awscli terraform deck jq
```

バージョン確認:

```bash
aws --version          # aws-cli/2.x
terraform -version     # >= 1.6
deck version           # >= 1.40
```

#### 1-2. IAM ユーザーと Customer Managed Policy の準備

個人 AWS アカウント側で以下を実施。本リポジトリでは **IAM ユーザー名 `terraform`** を Terraform 実行用ユーザーとして使う前提（別名でも可、その場合は以降のコマンドの `--user-name terraform` を読み替える）。

**(1) IAM ユーザーを作成**

IAM コンソール（または `aws iam create-user`）で `terraform` ユーザーを作成。コンソールサインインは不要、CLI 用途のみ。

**(2) Customer Managed Policy を作成**

ポリシー本体は ~5KB あり、IAM ユーザー inline policy の上限 (2048 バイト) を超えるので、必ず Customer Managed Policy として作る。

```bash
aws iam create-policy \
  --policy-name kong-ecs-testbed-terraform \
  --policy-document file://terraform/iam/terraform-execution-policy.json
# 出力された Policy.Arn を控える: arn:aws:iam::<account-id>:policy/kong-ecs-testbed-terraform
```

**(3) ユーザーにポリシーを attach**

```bash
aws iam attach-user-policy \
  --user-name terraform \
  --policy-arn arn:aws:iam::<account-id>:policy/kong-ecs-testbed-terraform

# 確認
aws iam list-attached-user-policies --user-name terraform
```

**(4) Access Key を発行**

IAM コンソール → User `terraform` → Security credentials → **Create access key** (Use case: Command Line Interface) で発行し、Access Key ID と Secret Access Key を控える。**Secret はこの画面でしか取得できない。**

> 💡 ポリシーの設計・対象サービスは [terraform/iam/README.md](terraform/iam/README.md) を参照。
> ⚠️ 上記 (2)〜(3) を `aws iam` CLI で操作するには、実行する側のユーザーに `iam:CreatePolicy` / `iam:AttachUserPolicy` 権限が必要。個人アカウントの管理者ユーザーで実施する。
> 📅 ローカル Access Key 運用はこの 0-setup.md 限定。継続運用は [1-gitops.md](1-gitops.md) で OIDC + IAM Role に移行する。

#### 1-3. `aws configure` で Profile を登録

プロファイル名は `kong-testbed` を使用する（他用途のクレデンシャルと衝突させない）。

```bash
aws configure --profile kong-testbed
# AWS Access Key ID     : <控えた Access Key ID>
# AWS Secret Access Key : <控えた Secret Access Key>
# Default region name   : ap-northeast-1
# Default output format : json
```

`~/.aws/credentials` と `~/.aws/config` に `[kong-testbed]` セクションが書き込まれる。

> ⚠️ Access Key / Secret は **`~/.aws/credentials` 以外には貼らない**こと（リポジトリ・メモファイル・チャット等に残さない）。漏洩した疑いがあれば即 IAM コンソールで Deactivate → ローテーション。

#### 1-4. ログイン確認とアカウント ID の取得

```bash
aws sts get-caller-identity --profile kong-testbed
```

返ってきた `Account` 値を控える。`Arn` が `arn:aws:iam::<account-id>:user/terraform` になっていることも確認。

> 💡 1-2(4) で Access Key を発行した直後は IAM の伝播待ちで `InvalidClientTokenId` / `AuthFailure` が ~30 秒ほど出ることがある。その場合は数秒待って再実行。

#### 1-5. `.env` の作成

```bash
cp .env.example .env
```

`.env` を編集する:

- `AWS_PROFILE=kong-testbed`（1-3 で登録したプロファイル名）
- `AWS_REGION=ap-northeast-1`
- `AWS_ACCOUNT_ID` に 1-4 で取得した値

シェルへの読み込み:

```bash
set -a; source .env; set +a
```

#### 1-6. 動作確認

```bash
aws ec2 describe-vpcs   --profile "$AWS_PROFILE" --region "$AWS_REGION"
aws ecs list-clusters   --profile "$AWS_PROFILE" --region "$AWS_REGION"
aws elbv2 describe-load-balancers --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

すべてエラーなく応答が返れば OK（リソースが空でも問題なし）。AccessDenied が出た場合は 1-2 のポリシー付与状況を確認。

> ✅ Step 1 完了条件:
> - `aws sts get-caller-identity --profile kong-testbed` で `Arn` が `user/terraform` で返る
> - 1-6 の 3 コマンドが AccessDenied なく応答する
> - `.env` に `AWS_PROFILE` / `AWS_REGION` / `AWS_ACCOUNT_ID` が設定されている

---

### Step 2. Kong Konnect Control Plane 構築（Terraform）

> **対象**: [terraform/konnect/](terraform/konnect/)
> **作成物**: Hybrid Control Plane (`kong-ecs-testbed-cp`) + DP 用 mTLS クライアント証明書

#### 2-1. `.env` に Konnect PAT を設定

`.env` の `KONNECT_PAT` に Konnect で発行した PAT (`kpat_...`) を貼り付ける。`KONNECT_SERVER_URL` は US Geo の既定値 (`https://us.api.konghq.com`) のままでよい。

```bash
set -a; source .env; set +a
```

#### 2-2. Terraform 実行

```bash
export TF_VAR_konnect_pat="$KONNECT_PAT"

cd terraform/konnect
terraform init
terraform plan
terraform apply
```

> 💡 PAT は `terraform.tfvars` には書かない（誤コミット防止）。`TF_VAR_konnect_pat` 環境変数のみで渡す。

#### 2-3. 確認

- Konnect 管理コンソール → **Gateway Manager** → **Control Planes** に `kong-ecs-testbed-cp` が表示される
- 出力された各値を控える（実値は `terraform output -json` で取得可能、cert/key は `sensitive`）

```bash
terraform output control_plane_id
terraform output control_plane_endpoint
terraform output telemetry_endpoint
```

> ✅ Step 2 完了条件:
> - `terraform apply` がエラーなく完了
> - Konnect コンソールに CP が表示される
> - `terraform/konnect/terraform.tfstate` が生成されている（Step 3 以降で remote_state 参照する）

詳細は [terraform/konnect/README.md](terraform/konnect/README.md) を参照。

### Step 3. AWS 基盤構築（VPC / ECS / ALB / Cloud Map / IAM）

> **対象**: [terraform/aws/](terraform/aws/)
> **作成物**: VPC + 2 Public Subnet (NAT なし) / ECS Cluster (Fargate) / ALB / Cloud Map 私設名前空間 / Task Execution Role / Task Role (ECS Exec 用) / 各種 SG

実際の httpbin・Kong DP の ECS Task / Service は Step 4 / 5 で同じディレクトリに追加する（`terraform apply` を都度実行）。

#### 3-1. `allowed_cidrs` を設定

```bash
cd terraform/aws
cp terraform.tfvars.example terraform.tfvars
# terraform.tfvars を編集して allowed_cidrs に自宅 / オフィスの IP/32 を入れる
```

#### 3-2. Terraform 実行

```bash
# aws configure --profile kong-testbed 済み + .env 読み込み済み前提
set -a; source ../../.env; set +a

terraform init
terraform plan
terraform apply
```

#### 3-3. 確認

```bash
terraform output alb_dns_name
terraform output ecs_cluster_name
terraform output service_discovery_namespace_name
```

ブラウザで `http://<alb_dns_name>/` にアクセスすると `no route matched (default)` の 404 テキストが返る（**この時点ではこれが正常**。Kong DP は Step 5 で配置）。

> ✅ Step 3 完了条件:
> - VPC / Subnet / IGW / SG / ECS Cluster / ALB / Cloud Map namespace / IAM Role がすべて作成される
> - `curl http://<alb_dns_name>/` で `404` が返る
> - AWS コンソールで ECS Cluster `kong-ecs-testbed-cluster` が `ACTIVE`

### Step 4. httpbin ECS サービスの配置

> **対象**: [terraform/aws/httpbin.tf](terraform/aws/httpbin.tf)（Step 3 の `terraform/aws/` に追加適用）
> **作成物**: httpbin タスク定義 / ECS Service / Cloud Map A レコード登録

イメージ・タスク数の既定値は [variables.tf](terraform/aws/variables.tf) の `httpbin_image` / `httpbin_desired_count`。`.env` で `TF_VAR_httpbin_image` 等を上書きできる。

#### 4-1. Terraform 適用

```bash
cd terraform/aws
set -a; source ../../.env; set +a   # TF_VAR_* を読み込む
terraform plan
terraform apply
```

#### 4-2. 確認

ECS Service `kong-ecs-testbed-httpbin` の `runningCount` が `1` になり、Cloud Map に `httpbin.kong-ecs-testbed.local` が登録される。

VPC 内からの DNS 解決確認 (任意 - DP デプロイ後にしか検証できない場合は Step 5 後に):

```bash
# 例: ECS Exec で起動済みコンテナに入って nslookup
aws ecs execute-command \
  --cluster kong-ecs-testbed-cluster \
  --task <task-id> \
  --container httpbin \
  --interactive --command "/bin/sh"
# (httpbin にはツールが入っていないので、Step 5 以降は DP 側コンテナでの確認推奨)
```

CloudWatch Logs `/ecs/kong-ecs-testbed/httpbin` にアクセスログが流れていれば OK。

> ✅ Step 4 完了条件:
> - ECS Service `kong-ecs-testbed-httpbin` が `RUNNING`
> - Cloud Map コンソールで `httpbin.kong-ecs-testbed.local` の A レコードがタスクの ENI Private IP を指している

### Step 5. Kong Gateway Data Plane の ECS 配置

> **対象**: [terraform/aws/kong_dp.tf](terraform/aws/kong_dp.tf)（Step 3-4 と同じ `terraform/aws/`）
> **作成物**: Secrets Manager (cert/key) / Kong DP タスク定義・サービス / ALB Target Group / Listener Rule
> **既定イメージ**: `kong/kong-gateway:3.13`（[variables.tf](terraform/aws/variables.tf) の `kong_dp_image` で上書き可）

#### 5-1. 前提

- Step 2 (Konnect TF) が apply 済みで `terraform/konnect/terraform.tfstate` がある
- Step 4 までの apply が成功している

#### 5-2. Terraform 適用

```bash
cd terraform/aws
set -a; source ../../.env; set +a
terraform plan
terraform apply
```

#### 5-3. DP の起動と CP 接続を確認

```bash
# CloudWatch Logs を tail
aws logs tail /ecs/kong-ecs-testbed/kong-dp --follow --profile "$AWS_PROFILE" --region "$AWS_REGION"

# 期待されるログ:
#   "successfully loaded 'cluster_events' for stream 'default'"
#   "[clustering] received 1 messages from control plane"
```

Konnect コンソール → **Gateway Manager** → 当該 CP → **Data Planes** にノードが `Connected` で表示されたら接続成功。

ALB Target Group のヘルスチェックも 1〜2 分で `healthy` になる:

```bash
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw kong_dp_target_group_arn) \
  --profile "$AWS_PROFILE" --region "$AWS_REGION"
```

#### 5-4. 動作確認（Route 未設定状態）

```bash
curl -i http://$(terraform output -raw alb_dns_name)/
# Kong がレスポンスを返す: HTTP/1.1 404 Not Found  + body {"message":"no Route matched..."}
```

`Server: kong/3.x` ヘッダがあれば Kong DP が応答できている（Step 6 で Service/Route を投入するまで Route なしの 404 が正常）。

> ✅ Step 5 完了条件:
> - Konnect コンソールで DP ノードが `Connected`
> - ALB Target Group が `healthy`
> - `curl http://<alb>/` の応答ヘッダに `Server: kong/...`

### Step 6. decK で Kong 設定を投入

> **対象**: [deck/kong.yaml](deck/kong.yaml)
> **作成物**: Konnect CP `kong-ecs-testbed-cp` 上の Service / Route / Plugin / Consumer

宣言ファイルの中身（Service `httpbin` → `httpbin.kong-ecs-testbed.local:80` / Route `/httpbin` / `rate-limiting` 60rpm/local / `key-auth` / Consumer `test-user`）と各サブコマンドの詳細は [deck/README.md](deck/README.md) を参照。

#### 6-1. テスト用 API キーを生成

```bash
# プロジェクトルートで .env を読み込み済み
set -a; source .env; set +a

# kong.yaml の ${DECK_API_KEY} を envsubst で置換する想定。export 必須。
export DECK_API_KEY="$(openssl rand -hex 24)"
echo "Test API key: $DECK_API_KEY"   # Step 7 の curl で使うので控える
```

> 💡 [deck/kong.yaml](deck/kong.yaml) の `${DECK_API_KEY}` プレースホルダのみコミット、実値は tfstate にも `.env` にも残さない。
> ⚠️ deck v1.53 時点では `${DECK_*}` の自動置換は state file に対して適用されない（render/sync いずれも無置換のままパースされる）。`envsubst` で前段処理する方式に統一する。
> ⚠️ deck v1.40+ では `--var` フラグも廃止されているため使わないこと。

#### 6-2. diff で差分を確認

```bash
# env が export されていることを必ず確認（未 export だと envsubst が空置換 → 401）
test -n "$DECK_API_KEY" && echo "DECK_API_KEY OK (len=${#DECK_API_KEY})" || echo "❌ DECK_API_KEY is empty"

deck gateway diff \
  --konnect-token "$KONNECT_PAT" \
  --konnect-addr  "$KONNECT_SERVER_URL" \
  --konnect-control-plane-name "$KONNECT_CP_NAME" \
  <(envsubst '${DECK_API_KEY}' < deck/kong.yaml)
```

初回は全リソースが `creating` として表示される。

#### 6-3. sync で投入

```bash
deck gateway sync \
  --konnect-token "$KONNECT_PAT" \
  --konnect-addr  "$KONNECT_SERVER_URL" \
  --konnect-control-plane-name "$KONNECT_CP_NAME" \
  <(envsubst '${DECK_API_KEY}' < deck/kong.yaml)
```

> 💡 `envsubst '${DECK_API_KEY}'` で対象 env を限定（明示しないと他の `${…}` も全部置換するので安全のため）。
> 💡 `<(...)` は process substitution。deck はパス引数として `/dev/fd/N` を受け付ける。
> 💡 `export DECK_API_KEY=...` であって `DECK_API_KEY=... deck ...` ではダメ（process substitution 側のサブシェルに env が伝わらず空置換になる）。

Konnect コンソール → 当該 CP → **Gateway Services** / **Routes** / **Plugins** / **Consumers** に反映を確認。DP には Konnect 側の差分配信で数秒〜十数秒以内に到達する（CloudWatch Logs `/ecs/kong-ecs-testbed/kong-dp` に config reload のログが出る）。

> ✅ Step 6 完了条件:
> - `deck gateway sync` が `Summary: ... Created` で終わる
> - Konnect コンソールで Service / Route / Plugin / Consumer が表示される
> - `deck gateway diff` を再実行すると `Summary: 0 changes` になる

---

### Step 7. 動作確認とクリーンアップ

#### 7-1. エンドツーエンドの疎通確認

ALB DNS を取得:

```bash
cd terraform/aws
ALB="$(terraform output -raw alb_dns_name)"
cd ../..
```

**(a) 認証なし → 401**

```bash
curl -i "http://$ALB/httpbin/anything"
# HTTP/1.1 401 Unauthorized
# {"message":"No API key found in request"}  ← key-auth が効いている
```

**(b) 認証あり → 200 + httpbin が応答**

```bash
curl -i "http://$ALB/httpbin/anything" -H "apikey: $DECK_API_KEY"
# HTTP/1.1 200 OK
# Server: kong/3.x
# X-RateLimit-Limit-Minute: 60
# X-RateLimit-Remaining-Minute: 59
# (httpbin が echo した JSON が body)
```

**(c) パスストリップの確認**

レスポンス body の `"url"` フィールドが `http://.../anything`（`/httpbin` が剥がれている）になっていれば `strip_path: true` が効いている。

**(d) レートリミット (60rpm) の発火**

```bash
for i in $(seq 1 65); do
  curl -s -o /dev/null -w "%{http_code}\n" \
    "http://$ALB/httpbin/anything" -H "apikey: $DECK_API_KEY"
done | sort | uniq -c
# 60  200
#  5  429   ← 上限超過は 429 Too Many Requests
```

#### 7-2. Konnect 側の確認

- **Gateway Manager** → 当該 CP → **Data Planes**: ノードが `Connected`
- **Analytics** (有効ライセンスがある場合): リクエスト数 / レイテンシ / ステータスコードが集計されている

#### 7-3. クリーンアップ

検証が終わったら逆順で破棄する。**必ず Konnect 側より AWS 側を先に**消すと、DP が落ちた状態で CP の cert revocation を行うことになり面倒なので、順序は次の通り:

```bash
# (1) Kong 設定を Konnect から削除
deck gateway reset \
  --konnect-token "$KONNECT_PAT" \
  --konnect-addr  "$KONNECT_SERVER_URL" \
  --konnect-control-plane-name "$KONNECT_CP_NAME" \
  --force

# (2) AWS 側を破棄（Kong DP / httpbin / ALB / VPC など全て）
cd terraform/aws
terraform destroy
cd ../..

# (3) Konnect Control Plane を破棄
cd terraform/konnect
terraform destroy
cd ../..
```

**ローカルの後始末:**

```bash
unset DECK_API_KEY KONNECT_PAT TF_VAR_konnect_pat
# .env を消す or PAT 行のみ空に戻す
```

> ✅ Step 7 完了条件:
> - 7-1 の (a)〜(d) がすべて期待どおりの応答
> - `terraform destroy` が両ディレクトリで成功し、AWS コンソールに `kong-ecs-testbed-*` の残骸がない
> - Konnect コンソールから CP `kong-ecs-testbed-cp` が消えている
