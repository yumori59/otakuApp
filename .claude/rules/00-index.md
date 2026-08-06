# 参戦名義帳 — Claude Code ルール集

このディレクトリは Claude Code 用の開発ルールを整理した場所。
リポジトリルートの `CLAUDE.md` から索引される。

## ファイル一覧

| ファイル | 内容 |
|---|---|
| `01-aidlc.md` | 計画先行開発の必須ルール |
| `02-agents.md` | エージェント使用ルール |
| `03-parallel-development.md` | 並列開発のルールと判断基準 |
| `04-review.md` | レビュー必須ルール |
| `05-harness.md` | 検証ゲートの方針 |
| `06-delegation-prompts.md` | サブエージェント委譲プロンプト (7 要素) |
| `07-quality-protocols.md` | 調査・計画・実装の思考プロトコル |
| `feedback_review_patterns.md` | 過去頻出バグパターンの SSOT |

## 既存ドキュメントとの関係

- ルート `CLAUDE.md` — 技術規約 (構成・ビルド/検証・DB・スタック) の土台。常時ロード
- `.claude/rules/*` — **Claude Code 固有の運用ルール**
- `docs/` — 製品仕様・設計の正（特に 01〜05）

技術規約は `CLAUDE.md` と既存実装 (`apps/api/src/`、`meigicho/`) を正とし、
本ディレクトリはワークフロー運用のみを扱う。
