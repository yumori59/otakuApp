# Rule 07: 品質プロトコル

## 原則

規約 (what) は `CLAUDE.md` と rules 01〜06。本 rule は **思考ステップ (how)** を場面ごとの skill として定め、デフォルト適用する。

| 場面 | 適用 skill | 起動タイミング |
|---|---|---|
| 調査 | `investigating-thoroughly` | 調べ始める前 + 報告確定直前 |
| 計画・設計 | `designing-development-plans` | 要件を受けた直後 |
| 実装 | `implementing-robustly` | 最初のコードの前 + 完了報告直前 |

## 適用の仕組み

- **メインセッション**: 該当タスクで対応 skill を読む
- **サブエージェント委譲**: プロンプトに「まず `.claude/skills/<name>/SKILL.md` を読み従う」を含める
- **プロジェクトエージェント**: 定義に該当 skill を必読として埋め込み済み

## 共通原則

1. **局所で結論しない** — 知識は `apps/api` / `meigicho` / Prisma / `docs/` に散在する
2. **「同等」「存在しない」「完了」は検証済み主張としてのみ書く**
3. **カバレッジの正直さ** — 未調査・対象外の理由・残課題を報告に含める

## 運用

このリポジトリで新たに観測された失敗は該当 skill の「よくある間違い」表と `feedback_review_patterns.md` へ追記する。
