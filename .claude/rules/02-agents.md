# Rule 02: エージェント使用

## 原則

開発作業は**該当するエージェントを使用して実行する**。
呼び出し時のプロンプトは `06-delegation-prompts.md` に従う。

## シーン別使用エージェント

| シーン | 使用エージェント | 役割 |
|---|---|---|
| 要件整理・計画 | `aidlc-planner` | Inception、`docs/plans/<feature>/` 生成 |
| 実装 (BE: controller/use-case/service/dto/Prisma) | `nest-developer` | NestJS 規約準拠 |
| 実装 (iOS: Features/Domain/Network/DataStore) | `swift-developer` | SwiftUI + パッケージ規約準拠 |
| 実装完了後・コミット/PR 前 | `code-reviewer` | 第三者レビュー |

## モデル振り分け

| エージェント | 既定 model | 理由 |
|---|---|---|
| `aidlc-planner` | opus | 要件構造化・設計判断 |
| `code-reviewer` | opus | 見落としコスト最大 |
| `nest-developer` | sonnet | 定型実装が主 |
| `swift-developer` | sonnet | 定型実装が主 |

**エスカレーション (実装)**: 複数モジュール新規ドメイン / 認証・同期 / 前例なし設計は `model: opus`。
**デエスカレーション (レビュー)**: 軽量チェックのみ `model: sonnet` 可。原則「reviewer は実装者の tier 以上」。

## 重要な分離

- **実装とレビューは別セッション**（自己レビュー禁止）
- **API 契約をまたぐ変更で BE と iOS を契約未確定のまま並列委譲しない** — 契約はオーケストレーターまたは planner が確定してから両 developer へ書き写す

## 使いすぎないこと

- 1機能あたり planner → developer (×N) → reviewer の 3 段で完結
- 単純な読み取り・grep はエージェント不要
