# Rule 01: 計画先行開発 (AIDLC ライト)

## 原則

このリポジトリでの開発は **計画 → テスト先行 → 実装 → レビュー** を基本フローとする。
（フル AIDLC 詳細リファレンス `.aidlc-rule-details/` と push ゲートは未導入。成果物は `docs/plans/` に置く）

## 必須

- 新機能・大きな改修・複数ファイルにまたがる修正は、**必ず `aidlc-planner` を最初に呼び出す**
- 計画産物は `docs/plans/<feature>/` に置き、リポジトリにコミットする
- 仕様の確定回答はファイルに残す（チャット流しっぱなし禁止）。軽い確認は即時取得してよいが、確定内容は `questions-*.md` または `requirements.md` へ書き戻す
- **Requirements / plan 完了前に実装に着手しない**
- **Construction は Spec-then-Test-Driven**（大きい/中程度）: 受入基準を失敗テストへ翻訳 (Red) してから実装 (Green)
- **iOS の例外**: XCTest が未整備なら、振る舞いロジックは Domain / Core の純粋関数か BE に寄せる。iOS のみの振る舞いは手動確認手順を plan に明記する

## 省略可

- typo 修正
- 1ファイル数行の bugfix
- 既存ドキュメント・コメントのみの更新

## フェーズ概要

```
Inception:    Requirements Analysis → Workflow Planning  → docs/plans/<feature>/
Construction: Test First (Red) → Code Generation (Green) → Build & Test → Review
```

詳細な思考ステップは `designing-development-plans` / `implementing-robustly` skills。
検証は `05-harness.md`。
