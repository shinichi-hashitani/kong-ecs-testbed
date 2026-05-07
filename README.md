# kong-ecs-testbed

AWS ECS (Fargate) 上に Kong Gateway の Data Plane を立て、Kong Konnect を Control Plane として連携するテスト環境。バックエンドには [`kennethreitz/httpbin`](https://hub.docker.com/r/kennethreitz/httpbin) を別 ECS サービスとして配置する。

複数のシナリオを段階的に実行できる構成にしてあり、各シナリオは独立した手順書 (`*.md`) として用意してある。

## アーキテクチャ概要

```
        ┌──────────────────────────────────────────────────┐
        │ Kong Konnect (SaaS, US Geo: api.konghq.com)      │
        │  └─ Control Plane: kong-ecs-testbed-cp           │
        └───────────────▲────────────────▲─────────────────┘
                        │ TLS (cluster)  │ HTTPS (admin/decK)
                        │                │
┌───────────────────────┼────────────────┼──────────────────────────────┐
│ AWS (ap-northeast-1)  │                │                              │
│                       │                │                              │
│   ┌─────────┐   ┌─────┴─────┐    ┌─────┴──────┐    ┌──────────────┐   │
│   │ Client  │──▶│   ALB     │───▶│ Kong DP    │───▶│ httpbin      │   │
│   └─────────┘   │ (proxy)   │    │ ECS (FG)   │    │ ECS (FG)     │   │
│                 └───────────┘    └────────────┘    └──────────────┘   │
│                                                                       │
│   VPC / public subnets only (no NAT) / SG / IAM / CloudWatch Logs     │
└───────────────────────────────────────────────────────────────────────┘
```

## ディレクトリ構成

```
.
├── README.md             # 本ファイル（概要・前提・シナリオインデックス）
├── 0-setup.md            # 初回セットアップ（Step 1〜7 を手動実行）
├── 1-gitops.md           # 作業の GitOps 化（GitHub Actions OIDC + IAM Role）
├── 2-kong-upgrade.md     # Kong 3.13 → 3.14 アップグレード（GitOps 経由）
├── .env.example          # 環境変数テンプレート
├── .gitignore
├── terraform/
│   ├── iam/              # IAM 最小権限ポリシー JSON
│   ├── bootstrap/        # GitOps 用 state backend + OIDC + IAM Role（1-gitops.md）
│   ├── konnect/          # Konnect Control Plane
│   └── aws/              # VPC / ECS / ALB / IAM Roles / httpbin / Kong DP
├── deck/                 # decK 設定
└── .github/workflows/    # GitOps パイプライン
```

## 前提条件

- macOS / Linux 開発マシン（`brew` または同等のパッケージ管理が使える）
- 個人 AWS アカウント（東京リージョン `ap-northeast-1` を使用）
- Kong Konnect の契約済みアカウント + PAT（US Geo: `https://us.api.konghq.com`）
- 必須ツール: `awscli` 2.x / `terraform` >= 1.6 / `deck` >= 1.40 / `jq`
- 任意: GitHub アカウントとリポジトリ push 権限（[1-gitops.md](1-gitops.md) 以降）

## ユースケース

クライアント → ALB → Kong Gateway DP → httpbin の経路で疎通する。Kong の Service / Route / Plugin 設定は decK 経由で Konnect CP に投入され、DP に配信される。Kong DP の既定バージョンは `3.13`（[terraform/aws/variables.tf](terraform/aws/variables.tf) の `kong_dp_image`）。

## シナリオ

| # | ファイル | 概要 | 前提 |
| --- | --- | --- | --- |
| 0 | [0-setup.md](0-setup.md) | ローカルマシンから手動で Konnect CP / AWS 基盤 / Kong DP / decK 設定を一通り構築する | 上記前提条件のみ |
| 1 | [1-gitops.md](1-gitops.md) | Terraform / decK の運用を GitHub Actions に移行する。OIDC + IAM Role で Access Key を排除 | シナリオ 0 完了 |
| 2 | [2-kong-upgrade.md](2-kong-upgrade.md) | Kong DP を 3.13 → 3.14 にアップグレードする。実際のデプロイは GitOps 経由 | シナリオ 1 完了 |

各シナリオは前のシナリオの完了状態を前提とする。新規参加者は **0 → 1 → 2** の順で実行する。

## 関連ドキュメント

- [terraform/iam/README.md](terraform/iam/README.md) — IAM ポリシーの設計と適用方法
- [terraform/konnect/README.md](terraform/konnect/README.md) — Konnect CP の Terraform 詳細
- [terraform/aws/README.md](terraform/aws/README.md) — AWS 側 `*.tf` のファイル構成
- [deck/README.md](deck/README.md) — decK サブコマンドと state file 構造
- [CLAUDE.md](CLAUDE.md) — Claude Code 用プロジェクトコンテキスト
