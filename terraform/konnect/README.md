# terraform/konnect

Kong Konnect 上に Hybrid モードの Control Plane を作成し、Data Plane が PKI mTLS で接続するためのクライアント証明書を発行する Terraform モジュール。

## 作成されるリソース

| リソース | 概要 |
| --- | --- |
| `konnect_gateway_control_plane.this` | Hybrid CP（`CLUSTER_TYPE_HYBRID`、`auth_type = pki_client_certs`） |
| `tls_private_key.dp` / `tls_self_signed_cert.dp` | DP 用の自己署名クライアント証明書（leaf）。1 年有効 |
| `konnect_gateway_data_plane_client_certificate.dp` | 上記 cert を Konnect CP に登録 |

## 入力

| 変数 | 必須 | デフォルト | 渡し方 |
| --- | --- | --- | --- |
| `konnect_pat` | ✅ | — | `TF_VAR_konnect_pat` 環境変数 |
| `konnect_server_url` | — | `https://us.api.konghq.com` | tfvars or env |
| `cp_name` | — | `kong-ecs-testbed-cp` | tfvars or env |
| `cp_description` | — | テスト用途 | tfvars or env |
| `labels` | — | `{project, env}` | tfvars or env |

## 出力

- `control_plane_id`
- `control_plane_endpoint`（DP の `KONG_CLUSTER_CONTROL_PLANE` に設定）
- `telemetry_endpoint`（DP の `KONG_CLUSTER_TELEMETRY_ENDPOINT` に設定）
- `dp_certificate_pem`（sensitive）
- `dp_private_key_pem`（sensitive）

`terraform/aws/` から `terraform_remote_state` データソース経由で参照する想定。

## 実行手順

```bash
# プロジェクトルートで .env を読み込み済みの前提
set -a; source .env; set +a
export TF_VAR_konnect_pat="$KONNECT_PAT"

cd terraform/konnect
terraform init
terraform plan
terraform apply
```

`apply` 後、Konnect 管理コンソール (Gateway Manager → Control Planes) に `kong-ecs-testbed-cp` が表示されれば成功。

## 注意

- **kong/konnect プロバイダのバージョン**: `versions.tf` で `~> 2.2` に固定。プロバイダの API 変更でリソース属性名が変わった場合は [Terraform Registry](https://registry.terraform.io/providers/Kong/konnect/latest/docs) を参照のこと。
- **証明書の管理**: 本モジュールは leaf 証明書のみ作成（簡易構成）。本番では中間 CA を Konnect 側に登録し、leaf を CA で署名する構成を推奨。
- **シークレットの取り扱い**: `dp_private_key_pem` はローカル tfstate に平文で保存される。tfstate ファイル自体は `.gitignore` 済み。
