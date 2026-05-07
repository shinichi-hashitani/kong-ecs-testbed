# deck/

Konnect Control Plane へ投入する Kong 設定の宣言。

## 内容

[kong.yaml](kong.yaml):
- Service `httpbin` (Cloud Map host `httpbin.kong-ecs-testbed.local`)
- Route `httpbin-route` (`/httpbin` に来たら `strip_path: true` で剥がして転送)
- Plugin `rate-limiting` (60 req/min/IP, local policy)
- Plugin `key-auth` (header/query `apikey` 必須)
- Consumer `test-user` + key-auth credential（キー値は `DECK_API_KEY` env で注入）

## 投入手順 (sync)

```bash
# プロジェクトルートで .env を読み込み済みの想定
set -a; source .env; set +a

# テスト API キー。export 必須（envsubst が process substitution 側に env を引き継ぐため）
export DECK_API_KEY="$(openssl rand -hex 24)"
echo "Test API key: $DECK_API_KEY"   # Step 7 の curl で使うので控える

# envsubst で kong.yaml 内の ${DECK_API_KEY} を実値に置換してから sync
deck gateway sync \
  --konnect-token        "$KONNECT_PAT" \
  --konnect-addr         "$KONNECT_SERVER_URL" \
  --konnect-control-plane-name "$KONNECT_CP_NAME" \
  <(envsubst '${DECK_API_KEY}' < deck/kong.yaml)
```

> ⚠️ deck v1.53 では state file 中の `${DECK_*}` を deck 自身が置換する機構が動作しなかったため、`envsubst` で前段処理する方式に統一している（`--var` フラグも v1.40+ で廃止）。
> 💡 `envsubst '${DECK_API_KEY}'` のように対象を明示すると、他の `${...}` パターンを誤置換しない。

## diff (sync 前の差分確認)

```bash
deck gateway diff \
  --konnect-token        "$KONNECT_PAT" \
  --konnect-addr         "$KONNECT_SERVER_URL" \
  --konnect-control-plane-name "$KONNECT_CP_NAME" \
  <(envsubst '${DECK_API_KEY}' < deck/kong.yaml)
```

## dump (現状を YAML として吐く - デバッグ用)

```bash
deck gateway dump \
  --konnect-token        "$KONNECT_PAT" \
  --konnect-addr         "$KONNECT_SERVER_URL" \
  --konnect-control-plane-name "$KONNECT_CP_NAME" \
  -o /tmp/current.yaml
```

## 注意

- **Konnect 専用 deck サブコマンド**: 古い `deck sync` は OSS Kong 用。Konnect 接続では `deck gateway sync` を使う。
- **API キー**: `${api_key}` プレースホルダはコミットして OK。実値は `--var` で渡し、tfstate にも .env にも書かない運用。
- **rate-limiting policy**: DP が複数になる場合は `policy: local` ではカウンタが分散する。`cluster` は Konnect Hybrid 非対応。`redis` を使うなら別途 ElastiCache が必要。
