# db-schema-and-deploy — avatar-upload

DB スキーマ変更の内容、本番への適用手順（**PR 説明に転記する内容**）、`deploy-api.yml` への `prisma db push` 追加の設計と影響。
判断の経緯は `questions-requirements.md` Q3 / Q5。

---

## 1. スキーマ変更

### 1.1 なぜ `users` / `profiles` の列ではなく別テーブルか

本番コンテナは `NODE_ENV=production` で起動時の `prisma db push` をスキップする（`apps/api/docker-entrypoint.sh:7-9`）。
スキーマの本番反映が漏れたままコードがデプロイされた場合の影響範囲を比べる。

Prisma は `include` / `create` / `update` の既定で**モデルの全スカラー列**を読む（`SELECT` / `RETURNING`）。

| 置き場所 | 未反映のままデプロイされた場合に `P2022 column does not exist` で 500 になる箇所 |
|---|---|
| `profiles.avatar_url` | `auth.service.ts:85,97,116,133,145,164,190,226`（**サインイン・新規登録の全経路**）、`me.service.ts:95,121`（GET/PATCH /v1/me）、`share-recipient-access.service.ts:65`（受信箱）、`share-recipients.service.ts:30,46,150` |
| `users.avatar_url` | 上記に加え `users` を読む全箇所（refresh・アカウント削除など） |
| **`user_avatars` テーブル（採用）** | **無し**。既存コードは新テーブルを参照しない。新コードは `P2021 table does not exist` を捕捉して「アバター無し」/ 503 に落とす |

「nullable にする」だけでは列の**不在**は防げない。別テーブル + 例外の捕捉で、未反映時の影響を**アバター機能だけ**に閉じ込める。

### 1.2 `apps/api/prisma/schema.prisma` の差分

```prisma
model User {
  // ...既存フィールドは変更しない
  avatar             UserAvatar?
}

/// アカウント本人のアイコン画像（avatar-upload）。行が無い = 未設定。
/// URL ではなく GCS のオブジェクトキーを持つ（URL は API が AVATAR_PUBLIC_BASE_URL から組み立てる）。
model UserAvatar {
  userId    String   @id @map("user_id") @db.Uuid
  objectKey String   @map("object_key")
  createdAt DateTime @default(now()) @map("created_at") @db.Timestamptz(6)
  updatedAt DateTime @updatedAt @map("updated_at") @db.Timestamptz(6)

  user User @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@map("user_avatars")
}
```

- 主キー = `user_id`（1 ユーザー 1 行。upsert のキー）。独立した `id` 列は持たない（`Profile` / `Entitlement` と同じ「ユーザーに従属する 1:1」の形）
- `onDelete: Cascade`: アカウント削除時に DB 行は自動で消える（`MeService.deleteAccount` の削除順序を変えない）
- `object_key` に UNIQUE は付けない（乱数キーで衝突しない。付けると不要なインデックスが増える）

### 1.3 本番に必要な正確な SQL（**PR 説明に貼る**）

実装者は**スキーマ編集後に下記コマンドで実際の SQL を生成し、この節と PR 説明を生成結果で置き換える**（Prisma のバージョン差で引用符・スキーマ修飾が変わり得るため）。

```bash
cd apps/api
git show origin/main:apps/api/prisma/schema.prisma > /tmp/schema.before.prisma
npx prisma migrate diff \
  --from-schema-datamodel /tmp/schema.before.prisma \
  --to-schema-datamodel prisma/schema.prisma \
  --script
```

実出力（Prisma 6.19.0 で生成）:

```sql
-- CreateTable
CREATE TABLE "user_avatars" (
    "user_id" UUID NOT NULL,
    "object_key" TEXT NOT NULL,
    "created_at" TIMESTAMPTZ(6) NOT NULL DEFAULT CURRENT_TIMESTAMP,
    "updated_at" TIMESTAMPTZ(6) NOT NULL,

    CONSTRAINT "user_avatars_pkey" PRIMARY KEY ("user_id")
);

-- AddForeignKey
ALTER TABLE "user_avatars" ADD CONSTRAINT "user_avatars_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "users"("id") ON DELETE CASCADE ON UPDATE CASCADE;
```

**任意の追加（推奨）**: Supabase は `public` スキーマを Data API（PostgREST）に公開し得るため、RLS を有効化しておく（ポリシー無し = anon / authenticated ロールからは不可視。Prisma が使う所有者ロールは RLS の対象外なので API の動作に影響しない。Prisma は RLS を管理しないので `db push` の差分にも出ない）。

```sql
ALTER TABLE "public"."user_avatars" ENABLE ROW LEVEL SECURITY;
```

性質:

- **加算のみ・非破壊**。既存テーブル・列・制約に触れない。ロックは新テーブル作成と `users` への FK 追加時の短時間の `SHARE ROW EXCLUSIVE` のみ
- **旧コードと共存可能**（旧コードは新テーブルを知らない）→ コードより**先に**適用してよい / 適用すべき
- ロールバック（不要になった場合のみ。**画像参照が消える**ので通常は行わない）: `DROP TABLE "public"."user_avatars";`

---

## 2. 本番デプロイ手順（**PR 説明の「本番反映手順」節に転記する**）

マージで `deploy-api.yml` が自動実行される。Terraform は手動（`terraform-apply.yml`）。順序は次のとおり。

### 2.1 マージ前（ユーザー作業）

1. **GitHub Secret の登録**（Q5 = A を採用する場合）
   - Settings → Secrets and variables → Actions → **Secrets** に `PROD_DATABASE_DIRECT_URL`
   - 値: Supabase → Project Settings → Database → Connection string → **Session pooler**（ポート **5432**、ユーザー名 `postgres.<project_ref>`、`?sslmode=require`）
   - **Transaction pooler（6543 / `pgbouncer=true`）は使わない**（DDL・prepared statement と相性が悪い）。**Direct connection（`db.<ref>.supabase.co`）も使わない**（IPv6 のみで GitHub ホストランナーから届かない）
2. **ドリフト確認**（初回のみ。§3.3）: ローカルから
   ```bash
   cd apps/api
   npx prisma migrate diff --from-url "$PROD_DATABASE_DIRECT_URL" --to-schema-datamodel prisma/schema.prisma --script
   ```
   出力が §1.3 の `CREATE TABLE` / `ADD CONSTRAINT` **だけ**であること。`DROP` が含まれていたら**マージしない**（本番に schema.prisma 外の変更がある。先に解消する）

### 2.2 マージ後（自動 → 手動）

| 順 | 何が | 内容 | 失敗時 |
|---|---|---|---|
| 1 | `deploy-api.yml` `test` | tsc / jest / build | デプロイされない |
| 2 | `deploy-api.yml` `db-schema` | 適用予定 SQL をログ出力 → `prisma db push --skip-generate` で §1.3 を適用 | `deploy` に進まない。旧リビジョンが稼働継続 |
| 3 | `deploy-api.yml` `deploy` | イメージ差し替え → `/health` | 旧リビジョン稼働継続。新テーブルは旧コードに無害 |
| 4 | **人**: Actions → `Terraform Apply` を main で手動実行 | GCS バケット・IAM・Cloud Run 環境変数（`AVATAR_BUCKET` / `AVATAR_PUBLIC_BASE_URL`） | 3 までは完了済みで、アップロードは 503 のまま（GET /v1/me は正常） |
| 5 | **人**: 疎通確認 | §2.4 | — |

**3 と 4 の間**は `AVATAR_BUCKET` 未設定のため `PUT /v1/me/avatar` は 503・`avatar_url` は `null`。**既存機能は影響を受けない**（FR-AV-11）。
iOS の新ビルドは 5 の確認後に配布する。

### 2.3 Q5 で B（CI に入れない）を選んだ場合

2.2 の 2 の代わりに、**マージ前**に人がローカルから適用する:

```bash
cd apps/api
DATABASE_URL="<Session pooler の接続文字列>" npx prisma db push --skip-generate
# もしくは Supabase SQL Editor で §1.3 の SQL を実行
```

適用を忘れてマージしても、本設計では**アバター機能が 503 になるだけ**で既存機能は落ちない（NFR-AV-1）。

### 2.4 本番の疎通確認

```bash
API=<terraform output cloud_run_url>
TOKEN=<テストアカウントの access token>

curl -fsS -H "Authorization: Bearer $TOKEN" "$API/v1/me" | jq '.profile.avatar_url'   # null
curl -fsS -X PUT -H "Authorization: Bearer $TOKEN" -F "file=@./sample.jpg;type=image/jpeg" "$API/v1/me/avatar" | jq -r '.profile.avatar_url' > /tmp/url
curl -fsSI "$(cat /tmp/url)"                       # 200, content-type: image/jpeg, cache-control: private, ...
curl -sS -o /dev/null -w '%{http_code}\n' "https://storage.googleapis.com/storage/v1/b/<bucket>/o"   # 401/403（一覧不可）
curl -fsS -X DELETE -H "Authorization: Bearer $TOKEN" "$API/v1/me/avatar" | jq '.profile.avatar_url'  # null
curl -sS -o /dev/null -w '%{http_code}\n' "$(cat /tmp/url)"   # 404（削除済み）
```

---

## 3. `deploy-api.yml` に `prisma db push` を追加する設計と影響

### 3.1 変更内容

```yaml
jobs:
  test:  # 既存のまま

  db-schema:
    needs: test
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: apps/api
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "22"
          cache: npm
          cache-dependency-path: apps/api/package-lock.json
      - run: npm ci
      - name: Require production DB URL
        env:
          DATABASE_URL: ${{ secrets.PROD_DATABASE_DIRECT_URL }}
        run: |
          if [ -z "${DATABASE_URL}" ]; then
            echo "::error::PROD_DATABASE_DIRECT_URL is not set. Schema must be applied before deploying (see docs/plans/avatar-upload/db-schema-and-deploy.md)."
            exit 1
          fi
      - name: Show pending schema changes
        env:
          DATABASE_URL: ${{ secrets.PROD_DATABASE_DIRECT_URL }}
        run: npx prisma migrate diff --from-url "$DATABASE_URL" --to-schema-datamodel prisma/schema.prisma --script
      - name: Apply schema (non-destructive)
        env:
          DATABASE_URL: ${{ secrets.PROD_DATABASE_DIRECT_URL }}
        run: npx prisma db push --skip-generate

  deploy:
    needs: [test, db-schema]   # 既存の needs: test を変更
    # 以下既存のまま
```

- `--accept-data-loss` は**付けない**。`--force-reset` も付けない
- 接続文字列はログに出ない（GitHub がマスク）。`migrate diff` の出力は DDL のみで値を含まない
- `concurrency: deploy-api`（既存）により並行実行されない
- ワークフローのヘッダコメント（「インフラの形は変更しない — ここはコードの入れ替えのみ」）を「DB スキーマの**加算的変更**も適用する」に更新する

### 3.2 何が変わるか（影響）

| 観点 | 影響 |
|---|---|
| 再発防止 | スキーマ反映漏れでコードだけがデプロイされる経路が消える（push が失敗すれば deploy されない） |
| 非破壊性 | `db push` は列・テーブルの削除や型変更など**データ損失を伴う差分があると `--accept-data-loss` 無しでは失敗**する。破壊的変更は必ず人の判断（手動適用）に戻る |
| 適用順 | **スキーマ → コード**の順になる。旧コードが新スキーマ上で動く時間があるため、自動で通すのは後方互換な加算変更（テーブル追加・nullable 列追加・デフォルト付き列追加・インデックス追加）に限られる。これを本リポジトリの規約として `docs/03-database.md` に追記する（expand → deploy → contract） |
| 失敗しうる非破壊変更 | NOT NULL・デフォルト無しの列追加（既存行あり）、既存データが違反する UNIQUE 追加などは push が失敗する → deploy も止まる（安全側） |
| ロールバック | Cloud Run のリビジョンを戻してもスキーマは戻らない。加算変更のみ自動適用する前提なので旧コードは動く |
| 権限・秘密 | **CI が本番 DB の DDL 権限付き接続文字列を持つ**。`main` に入ったワークフロー変更で読み出され得るので、`main` のブランチ保護（レビュー必須）が前提。リポジトリ Secret（Environment Secret ではない）にする理由: `deploy` ジョブに `environment: production` を付けると Required reviewers の設定次第で**全デプロイが承認待ち**になり現行運用が変わるため。承認を挟みたいなら `db-schema` ジョブにだけ `environment: production` を付けて Secret を Environment 側へ移す（任意） |
| ドリフト | 本番の `public` に schema.prisma 外のテーブル・列があると、push はそれを DROP しようとして毎回失敗する（＝**全デプロイ停止**）。初回導入前に §2.1-2 で確認する。Supabase 管理のスキーマ（`auth` / `storage` / `extensions` 等）は Prisma の対象外（`public` のみ）なので影響しない |
| 拡張機能 | `infra/postgres/init/01-extensions.sql` 由来の拡張は `public` のテーブルではないので push の対象外 |
| 所要時間 | `npm ci` + push で +1〜2 分 |
| Secret 未設定 | fail-closed（ジョブ失敗 → デプロイされない）。**本 PR のマージ前に Secret 登録が必要**。登録できない事情があるなら Q5 を B に変更し、`db-schema` ジョブを入れない |

### 3.3 将来

`prisma migrate`（`prisma/migrations/` + `migrate deploy`）へ移行すれば、適用履歴が残り破壊的変更も計画的に流せる。
既存本番 DB のベースライン化（`prisma migrate diff --from-empty ... > 0_init/migration.sql` → `migrate resolve --applied 0_init`）が必要なため**別計画で起票を推奨**。その時点で `db-schema` ジョブの `db push` を `migrate deploy` に置き換える。

---

## 4. PR 説明テンプレート（実装完了時に `plan.md` の担当者がこの形で書く）

```markdown
## 概要
アカウント設定画面でプロフィールアイコン（アバター画像）を設定・削除できるようにしました。
画像は端末で正方形 512px の JPEG に変換してアップロードし、サーバーでも再エンコード（位置情報などのメタデータを除去）して GCS に保存します。
アイコンは本人にしか表示されません（共有相手には表示しません）。

## 変更点
- API: `PUT /v1/me/avatar`（multipart, field `file`, JPEG/PNG, 最大 5MB）/ `DELETE /v1/me/avatar` を追加。`GET /v1/me` の `profile.avatar_url` を追加
- DB: `user_avatars` テーブルを追加（既存テーブルは変更なし）
- インフラ: GCS バケット `<project_id>-avatars`・IAM・Cloud Run 環境変数（Terraform）
- CI: `deploy-api.yml` に `db-schema` ジョブ（非破壊 `prisma db push`）を追加
- iOS: アカウント設定でのアイコン設定・削除、ホーム左上の入口にアイコン表示

## ⚠️ 本番 DB に必要なスキーマ変更
（§1.3 の SQL を `prisma migrate diff` の実出力で貼る）
- 加算のみ・非破壊。旧コードと共存可能。**コードより先に適用**
- 未適用のままデプロイされても、アバター機能が 503 になるだけで既存機能は影響を受けません

## 必要なセットアップ
1. GitHub Actions Secret `PROD_DATABASE_DIRECT_URL`（Supabase Session pooler / 5432）
2. マージ後に `Terraform Apply` を手動実行（バケット・IAM・環境変数）
3. 環境変数（すべて非機密・Terraform が設定）: `AVATAR_BUCKET` / `AVATAR_PUBLIC_BASE_URL`（ローカルのみ `GCS_API_ENDPOINT`）
4. App Store Connect の App Privacy に「写真またはビデオ」を追加
5. （`.env.example` に書けなかった場合）手動で 3 変数を追記

## テスト方法
- `cd apps/api && npx tsc --noEmit && npm test && npm run build`
- ローカル: `make up` → curl 手順（docs/plans/avatar-upload/plan.md §7.2）
- iOS: xcodebuild + 手動確認（plan.md §7.4）
- 本番: db-schema-and-deploy.md §2.4
```
