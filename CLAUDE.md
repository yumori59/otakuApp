# CLAUDE.md

**参戦名義帳** — 複数 FC 名義とライブ申込・当落を管理するアプリ。
**iOS クライアント (Swift 6 / SwiftUI)** + **バックエンド (NestJS + Prisma + PostgreSQL)** のモノレポ。

- 認証: **Sign in with Apple → NestJS が JWT 発行**（Supabase Auth / PostgREST は使わない）
- DB: **Supabase PostgreSQL（ホスティングのみ）**。NestJS + Prisma が唯一の DB クライアント
- 実行: GCP Cloud Run（`infra/`）。ローカルは Docker Compose + Makefile
- 仕様の正: `docs/`（特に `01-product-overview.md` / `02-architecture.md` / `03-database.md` / `04-api.md` / `05-ios-client.md`）

## ビルド・実行コマンド

```bash
make up                 # Docker で DB + API 起動 (API: http://localhost:8080)
make down               # 停止
make health             # /health と /readyz
make db-only            # DB のみ (ホストで API 開発するとき)
make api-dev            # ホストで NestJS watch (要: make db-only + npm install)
make prisma-push        # apps/api で prisma db push
```

iOS は `meigicho/Meigicho.xcodeproj` を Xcode で開く（生成は `meigicho/project.yml` + XcodeGen）。
環境変数は `apps/api/.env.example` → `.env`（gitignore 済み）。

## 検証ゲート (完了条件)

BE:
```bash
cd apps/api && npx tsc --noEmit
cd apps/api && npm test -- --passWithNoTests
cd apps/api && npm run build
```

iOS:
```bash
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build
```

`npm test` (jest) は振る舞い実装の完了ゲート。新機能・複数ファイル・挙動変更はテスト先行 (Red→Green)。
詳細は `.claude/rules/05-harness.md`。

既知の未整備 (ゲート対象外。整備したら本節に追加する):

- pre-commit / Claude Code hooks は未導入（ハーネス Phase B 外）。CI (GitHub Actions) は導入済み — `.claude/rules/05-harness.md` 参照
- 本番コンテナ起動時の自動 `prisma db push` は `NODE_ENV=production` でスキップする（`apps/api/docker-entrypoint.sh`）。DB スキーマ変更は当面、人が明示的に `prisma db push` / 将来的な `prisma migrate deploy` を実行する運用
- iOS XCTest は設計書上は各パッケージに置く想定だが、機械ゲートは現状ビルド成功のみ
- NestJS ドメインモジュール（auth/me/identities/memberships/tours/events/applications/shares）は実装済み（`docs/plans/backend-domain-modules/`）。iOS 側（Network/DataStore）は `docs/plans/ios-network-integration/` で追従済み
- 認証拡張（Google Sign-In・メール+パスワード・パスワードリセット）と共有 write 権限（軽量共同編集）も実装済み（`docs/plans/backend-auth-and-shares-extension/`）。契約は `api-contract-delta.md` が正
- **共有はアカウント招待制**（2026-08-07・`docs/plans/share-account-invites/`）。`public` モジュール（`GET/PATCH /public/shares/:token`）は**削除済み**。受け取りは Bearer 必須の `shares/received/*`（受信箱）に一本化。契約は `docs/plans/share-account-invites/api-contract-delta.md` が正。レビュー待ち（`docs/plans/STATUS.md` §9 参照）
- 実 DB（Docker）を使った統合テストは未整備。現状は Prisma モックによる unit test のみ（`prisma db push` はローカル Docker DB に反映済み）
- `apps/api/.env.example` への `GOOGLE_CLIENT_IDS` / `GOOGLE_ISSUER` / `GOOGLE_JWKS_URL` / `RESEND_API_KEY` / `RESEND_FROM_EMAIL` 追記はハーネスの deny 設定でエージェントが書けないため未検証。手動確認が必要
- 本番運用前に必須: Resend を `docs/08-compliance-risk.md` の委託先一覧に追記、パスワードリセットのメール送信基盤の法務確認

## ディレクトリ構成

```
apps/api/                 NestJS API
  src/                    Controller → UseCase → Service → Prisma (ADR-009)
    health/ prisma/       現状の最小実装
  prisma/schema.prisma    DB スキーマの正
meigicho/                 iOS (XcodeGen: project.yml)
  App/                    @main・Composition Root
  Packages/
    Core/ DesignSystem/ Domain/ Features/
    (DataStore / Network は設計上予定 — 未作成なら docs/05 を正とする)
docs/                     仕様・設計の正 (00〜10)
docs/plans/               機能単位の計画産物 (planner 出力先)
infra/                    インフラ (GCP 等)
.claude/                  Claude Code 運用 (rules / agents / skills)
```

## DB 変更フロー (Prisma)

**正は `apps/api/prisma/schema.prisma`**。prisma コマンドは必ず `apps/api/` で実行する。

1. `apps/api/prisma/schema.prisma` を編集
2. ローカル開発は `make prisma-push` または `cd apps/api && npx prisma db push`（本番は migration 方針を `docs/03-database.md` に従う）
3. ID は **UUID**（クライアント発行 UUID v7 前提 — `docs/03` ADR）。cuid 前提や UUID 以外の検証を持ち込まない
4. iOS（Domain / Network / DataStore）への追従を影響範囲に含める

## コーディング規約・ワークフロー

技術規約の正はこの `CLAUDE.md` と `docs/`、および既存実装。
Claude Code 運用は `.claude/rules/` を参照:

| ファイル | 内容 |
|---|---|
| `01-aidlc.md` | 計画先行フロー (Inception → Construction、テスト先行) |
| `02-agents.md` | エージェント使い分け |
| `03-parallel-development.md` | 並列開発の判断基準 |
| `04-review.md` | レビュー必須 |
| `05-harness.md` | 検証ゲート |
| `06-delegation-prompts.md` | 委譲プロンプトの書き方 |
| `07-quality-protocols.md` | 調査・計画・実装の思考プロトコル |
| `feedback_review_patterns.md` | 頻出バグパターン SSOT |

- 新機能・大改修は **`aidlc-planner` を最初に呼ぶ**（`docs/plans/<feature>/` に成果物）
- 実装は `nest-developer` / `swift-developer`、レビューは **別セッションで** `code-reviewer`
- **API 契約は iOS (Network/Domain) ↔ NestJS (dto/controller) ↔ Prisma (schema) の 3 層** — 片側だけ変えない
- BE レイヤは **Controller → UseCase → Service → Prisma**。Controller / UseCase から Prisma を直接叩かない

## ハーネス (現状)

- `.claude/settings.json`（共有）に deny / autoMode。`settings.local.json` は個人用（gitignore）
- `.env` / 秘密鍵の読取、DB 破壊操作、force push は autoMode で deny
- hooks / pre-commit / CI は未導入 — 検証ゲートはエージェント完了時に手動実行する
