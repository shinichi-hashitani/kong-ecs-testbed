# CLAUDE.md

このファイルは Claude Code 用のプロジェクトコンテキスト。詳細は各 README を参照。

## プロジェクト概要

AWS ECS Fargate 上に Kong Gateway DP を立て、Kong Konnect (SaaS, US Geo) を CP として連携するテスト環境。バックエンドは httpbin。経路は `Client → ALB → Kong DP (Fargate) → httpbin (Fargate)`。検証用途で本番運用ではない。

シナリオは番号付き .md に分割:
- [0-setup.md](0-setup.md) — 初回セットアップ Step 1〜7
- [1-gitops.md](1-gitops.md) — GitHub Actions による GitOps 化
- [2-kong-upgrade.md](2-kong-upgrade.md) — Kong 3.13 → 3.14 アップグレード

## 環境前提

- AWS リージョン: `ap-northeast-1`
- AWS 認証: 個人アカウントの IAM ユーザー Access Key を `aws configure --profile kong-testbed` で登録（saml2aws は使わない）
- IAM ユーザー名: `terraform`（[terraform/iam/terraform-execution-policy.json](terraform/iam/terraform-execution-policy.json) を Customer Managed Policy として attach。inline は 2048 byte 上限を超えるため不可。現状 4883 byte / 6144 上限）。GitOps 移行で OIDC Provider / S3 / DynamoDB の権限が含まれている。policy 更新は権限昇格防止により terraform ユーザ自身では不可、IAM コンソール手動更新
- Konnect Geo: US (`https://us.api.konghq.com`)
- Terraform state: ローカル（バックエンド未構成）
- 設定値は `.env` に集約（`.env.example` がテンプレ、`.env` は gitignore）

## ディレクトリ構成

```
README.md                                # 概要・前提・シナリオインデックス
0-setup.md / 1-gitops.md / 2-kong-upgrade.md  # シナリオ別手順書
.env.example                             # 環境変数テンプレ
terraform/iam/                           # IAM 実行ポリシー JSON + 適用手順
terraform/bootstrap/                     # state backend + OIDC + IAM Role（1-gitops.md）
terraform/konnect/                       # Konnect Control Plane + DP 用クライアント証明書
terraform/aws/                           # VPC / ECS / ALB / IAM / Cloud Map / httpbin / Kong DP
deck/                                    # decK state file (kong.yaml) + sync 手順
.github/workflows/                       # GitOps パイプライン (terraform-aws / terraform-konnect / deck-sync)
```

各ディレクトリに README あり。各 `*.tf` の役割は [terraform/aws/README.md](terraform/aws/README.md) のテーブル参照。

## 主要ワークフロー

```bash
# 共通: .env と AWS profile を読む
set -a; source .env; set +a

# Konnect CP 作成
cd terraform/konnect && terraform init && terraform apply

# AWS 基盤 + httpbin + Kong DP
cd ../aws && terraform init && terraform apply

# Kong 設定投入
cd ../..
export DECK_API_KEY="$(openssl rand -hex 24)"
deck gateway sync \
  --konnect-token "$KONNECT_PAT" \
  --konnect-addr  "$KONNECT_SERVER_URL" \
  --konnect-control-plane-name "$KONNECT_CP_NAME" \
  <(envsubst '${DECK_API_KEY}' < deck/kong.yaml)

# E2E 確認
curl -H "apikey: $DECK_API_KEY" "http://$(cd terraform/aws && terraform output -raw alb_dns_name)/httpbin/get"
```

## 注意事項 / 落とし穴

- **deck v1.53 は state file 内の `${DECK_*}` を置換しない**。`--populate-env-vars` も Go template `{{ env }}` も無効。**必ず `envsubst` で前段処理**（process substitution `<(envsubst ... < kong.yaml)` 形式）。`--var` は v1.40+ で廃止。詳細は [deck/README.md](deck/README.md)。
- **`export DECK_API_KEY=...` 必須**。`DECK_API_KEY=... deck ...` のインライン形式だと process substitution 側のサブシェルに env が引き継がれず空置換される。
- **ECS Exec を使うサービスは Task Role 必須**。`ssmmessages:*` 権限を Task Role に付与（[terraform/aws/iam.tf](terraform/aws/iam.tf)）。
- **Kong DP コンテナの cluster cert は env で直接渡す**。`KONG_CLUSTER_CERT` / `KONG_CLUSTER_CERT_KEY` に PEM をそのまま注入する方式（Secrets Manager → ECS task `secrets`）。`/docker-entrypoint.sh` を override して file 書き出しする方式は壊れる。
- **`terraform.tfvars` は gitignore 済み**。`allowed_cidrs` に自宅/オフィス IP を入れる用途で、誤コミット防止のため。GitOps 後は GitHub Secret `ALLOWED_CIDRS` に HCL list literal で保存（`["1.2.3.4/32"]` 形式）。
- **kong/konnect provider のリソース名は `konnect_gateway_data_plane_client_certificate`**（underscore 区切り。`dataplane` 一語ではない）。
- **IAM ポリシー更新は権限昇格防止により terraform user 自身では不可**。IAM コンソールから手動更新する想定。
- **terraform/aws と terraform/konnect は backend "s3" {} 空ブロック**。`-backend-config` で bucket/key/region/dynamodb_table を渡す partial config 形式。bootstrap apply 後に `terraform init -migrate-state -backend-config=...` で local → S3 移行する。
- **GitHub Actions workflow に preflight ジョブあり**。`vars.TF_STATE_BUCKET` 等が未設定のとき plan/apply を skip する。bootstrap 未完了時の PR で workflow 失敗にならないため。

## バージョン基準

- Kong DP 既定: `kong/kong-gateway:3.13`（[terraform/aws/variables.tf](terraform/aws/variables.tf) の `kong_dp_image`）。アップグレードシナリオ（[2-kong-upgrade.md](2-kong-upgrade.md)）はこの値を起点とする。
