# ローカル開発（Docker）

参戦名義帳のバックエンド（NestJS）と PostgreSQL を Docker Compose で起動します。
本番構成は [docs/06-infrastructure.md](./docs/06-infrastructure.md) を参照してください。

## 前提

- Docker Desktop（または Docker Engine + Compose v2）
- ポート `5432`（PostgreSQL）と `8080`（API）が空いていること

## クイックスタート

```bash
# リポジトリルートで
make up

# 起動確認
make health
# => {"status":"ok"}
# => {"status":"ready","database":"connected"}
```

停止:

```bash
make down
```

## 構成

| サービス | イメージ | ポート | 説明 |
|---------|---------|--------|------|
| `db` | postgres:16-alpine | 5432 | PostgreSQL。初回起動時に拡張（pgcrypto, pg_trgm）を有効化 |
| `api` | `./apps/api/Dockerfile` | 8080 | NestJS API。起動時に Prisma でスキーマを反映 |

## 環境変数

`apps/api/.env.example` をコピーして `.env` を作成します（ホスト開発時）。

```bash
cp apps/api/.env.example apps/api/.env
```

Docker Compose 利用時は `docker-compose.yml` 内の環境変数が使われます。

| 変数 | ローカル既定値 |
|------|---------------|
| `DATABASE_URL` | `postgres://meigicho:meigicho@db:5432/meigicho`（Compose 内） |
| `JWT_ACCESS_SECRET` | 開発用ダミー値 |
| `PORT` | `8080` |

## 開発パターン

### A. 全部 Docker（おすすめ・手軽）

```bash
make up
make logs   # API / DB ログを追う
```

### B. DB のみ Docker、API はホストで hot reload

```bash
make db-only
cd apps/api
cp .env.example .env   # DATABASE_URL は localhost:5432
npm install
npm run prisma:push
npm run start:dev
```

## API エンドポイント（現時点）

| Method | Path | 説明 |
|--------|------|------|
| GET | `/health` | 生存確認（DB 不要） |
| GET | `/readyz` | DB 接続確認 |

今後 `/v1/*` の REST API を [docs/04-api.md](./docs/04-api.md) に沿って追加します。

## スキーマ

Prisma スキーマ: `apps/api/prisma/schema.prisma`  
設計の正: [docs/03-database.md](./docs/03-database.md)

```bash
cd apps/api
npm run prisma:push    # スキーマ反映
npm run prisma:studio  # データブラウザ（要 DB 起動）
```

## トラブルシュート

**ポート競合**

```bash
lsof -i :5432
lsof -i :8080
```

**DB を初期化し直す**

```bash
docker compose down -v
make up
```

**API ビルドをやり直す**

```bash
docker compose build --no-cache api
docker compose up -d api
```

**`project name must not be empty`（日本語パスなど）**

リポジトリを日本語名のフォルダに置いている場合、Compose のプロジェクト名が空になることがあります。
`docker-compose.yml` 先頭の `name: meigicho`、または `COMPOSE_PROJECT_NAME=meigicho docker compose ...` を使ってください。

**Docker daemon に接続できない**

Docker Desktop が起動していることを確認してください。
