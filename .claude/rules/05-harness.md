# Rule 05: ハーネス・自動チェック

検証コマンドの実体はルート `CLAUDE.md` の「検証ゲート」節が SSOT。本ファイルは運用ルールのみ。

## テストは一級の完了ゲート

`cd apps/api && npm test` は振る舞い実装の完了ゲート。

- **大きい/中程度 (テスト先行 必須)**: 新機能・複数ファイル・振る舞い変更・再発防止 bugfix → Red→Green
- **小さい (省略可)**: typo・1ファイル数行・配線/設定/型定義・スキーマのみ・文言のみ
- **iOS**: 機械ゲートは現状 `xcodebuild` ビルド成功。振る舞いは Domain/Core か BE に寄せる。手動確認手順を報告に含める
- **完了報告**は ①変更ファイル ②実行した検証コマンドと結果 ③残課題。曖昧な「完了しました」のみは不可

## `/loop` による Green 駆動

非自明な実装のみ。小さい変更では使わない。

```
/loop cd apps/api && npm test が全て通り npx tsc --noEmit がクリーンになるまで実装を反復
/loop xcodebuild (CLAUDE.md のコマンド) が BUILD SUCCEEDED になるまで実装を反復
```

## CI/CD (2026-08-07 導入)

`main` への `apps/api/**` 変更マージで `.github/workflows/deploy-api.yml` が
test → build → Cloud Run デプロイまで自動実行する（GitHub リポジトリ未作成の間は動かない）。
インフラ（Cloud Run 設定・IAM・Secret Manager）は `infra/terraform/` が正。
詳細は `docs/06-infrastructure.md` §7 と `infra/terraform/README.md`。

## 未導入 (意図的に Phase B 外)

| 項目 | 状態 |
|---|---|
| pre-commit hook | 未導入 — コミット前に検証ゲートを手動実行 |
| Claude Code Pre/PostToolUse hooks | 未導入 — `settings.json` は deny/autoMode のみ |
| CI での lint/format 強制 | 未導入（test/build のみ） |
| push 前の review.md 強制 | 未導入 — 運用ルール (`04-review.md`) でカバー |

導入するときは本ファイルと `CLAUDE.md` を更新する。

## FE (iOS) エージェント完了条件

`xcodebuild build` が BUILD SUCCEEDED になって初めて「完了」。
API をまたぐ変更は手動確認手順（どの画面で何を確認するか）を報告に含める。
