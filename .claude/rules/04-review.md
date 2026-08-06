# Rule 04: レビュー必須

## 原則

実装エージェントの「完了」報告は**完了とみなさない**。`code-reviewer` で重大事項ゼロを確認するまでが完了。

## レビュータイミング

| タイミング | 対象 |
|---|---|
| 実装完了直後 | 当該差分 |
| コミット前 | ステージング差分 |
| PR 作成前 | ブランチ全差分 |

## レビュー観点

1. アーキテクチャ: BE は Controller → UseCase → Service → Prisma / iOS は View → Store → Repository → Local/Network
2. エラーハンドリング: NestJS 標準例外 + DTO 検証 / iOS は既存エラー・状態パターンに揃える
3. **頻出バグパターン** (`feedback_review_patterns.md`)
4. **API 契約 3 層**（Prisma ↔ NestJS ↔ iOS Domain/Network）と UUID 前提
5. セキュリティ: Guard / `ownerId` スコープ漏れ、秘密情報の漏洩、共有リンクのマスキング
6. テスト: BE `*.spec.ts`。iOS はビルド + 手動確認手順（またはパッケージテストがあれば実行）
7. **既存コードとの平仄**（命名・レイヤ・DTO・Feature 構成）

## 出力

- 重大 / 中 / 軽微 / 良かった点
- 重大ゼロでない場合は修正して再レビュー
- 製品コードのレビュー結果は可能なら `docs/plans/<feature>/review.md` に保存

## 自己レビュー禁止

実装したエージェントとは**別セッションで** `code-reviewer` を呼ぶ。
