# 過去頻出バグパターン (SSOT)

このファイルが**頻出バグパターンの単一の正**。
`04-review.md` / `code-reviewer` / `nest-developer` / `swift-developer` は本ファイルを参照する。
**重複コピーを各所に置かない**。

実害が出たパターンを載せる。初期セットは設計上の再発リスク（観測前の予防観点）。
新たに再発したらレビュー後にここに追記する。

---

## バックエンド (NestJS: apps/api)

| # | パターン | 検出観点 |
|---|---|---|
| BE-1 | **ID 型の契約ミス** | 主キーは UUID（クライアント発行 UUID v7）。cuid 前提や誤った pipe / 検証を持ち込まない。`:id` は契約どおり受け、service で存在・所有者確認 |
| BE-2 | **クエリ/ボディ enum の黙殺フォールバック** | 未知値を黙って別値に落とさない。受理側・DTO・iOS 送信値を揃える。未知は 400 か明示ログ |
| BE-3 | **レイヤ違反 (Prisma 直叩き)** | Controller / UseCase から Prisma を直接叩かない。Service まで。ADR-009 |
| BE-4 | **Guard / ownerId スコープ漏れ** | 認証必須エンドポイントに Guard 漏れ、他ユーザーの id 直指定で読み書きできる経路は重大。共有公開 API は意図的に公開しマスキングを確認 |
| BE-5 | **prisma 実行ディレクトリ間違い** | 正は `apps/api/prisma/schema.prisma`。コマンドは `apps/api/` で実行 |
| BE-6 | **Prisma 例外の envelope 漏れ** | P2002(既存idへのPOST)/P2025(対象行なし)が AllExceptionsFilter で INTERNAL 500 になっていないか。契約上の CONFLICT 409/NOT_FOUND 404 に写すか、Service 側で事前検出する |

## iOS (SwiftUI: meigicho)

| # | パターン | 検出観点 |
|---|---|---|
| IOS-1 | **未接続 View / Feature のデッドコード化** | 新規画面は遷移元・`AppRoute` / Tab 配線までが完了。死にコードを手本にしない |
| IOS-2 | **API 契約のパース追従漏れ** | BE のフィールド追加・改名・enum 変更に Network/Domain が追従しないと黙って欠落する。BE 変更時は対向を必ず grep |
| IOS-3 | **UI だけ在って配線が無い** | ボタン空・Repository 未接続・Sync 未配線。縦串 (UI→Store→Repository→Local/API) が通って完了 |
| IOS-4 | **仕様にない入力制約 / プラン上限の誤実装** | Free 名義上限など仕様と矛盾するバリデーション。`docs/01` / `07` と突き合わせる |
| IOS-5 | **パッケージ依存の逆流** | Features が DataStore/Network を直接参照しない（Composition Root で注入）。Domain に SwiftData を持ち込まない（`docs/05`） |

---

## 運用

- レビューは本表をチェックリストとして使う
- 実装時に本表を意識する
- 新規再発は修正後に 1 行追記する
