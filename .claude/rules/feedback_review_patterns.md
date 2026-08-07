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
| IOS-6 | **`AuthState.signedOut` = ログアウトと決めつける** | オフライン起動の復帰失敗 (`SessionRestoreResult.unavailable`) でも `.signedOut` になる。ここでローカル DB / 同期カーソルを消すと未送信の編集が飛ぶ。破棄は Keychain のトークンが実際に消えているかで判定する |
| IOS-7 | **SDK をリンクしただけで起動時に落ちる設定を空のまま置く** | GoogleMobileAds の `GADApplicationIdentifier` は空文字 / キー欠落だと SDK が起動時検証で NSException を投げる（`GADMobileAds.start` を呼ばなくても落ちる）。「未設定なら初期化しない」ファクトリでは防げない。SDK 追加時は `xcodebuild build` だけで完了とせず、**シミュレータに install → launch してプロセス生存を確認**する |
| IOS-8 | **`project.yml` を直して `xcodegen generate` を忘れる** | ビルド設定と Info.plist の変数展開は `Meigicho.xcodeproj/project.pbxproj` に焼き込まれている。再生成しないと変更が効かず「直したのに直らない」になる |
| IOS-9 | **`GeometryReader` で高さを固定して子を包む** | `GeometryReader` は子をクリップせず理想サイズも尊重しない。固定高で包むと中身が後続コンテンツに重なる。高さは `.frame(minHeight:)` で下限として確保し、`GeometryReader` は `background` に置いて幅の計測だけに使う |
| IOS-10 | **`UIViewRepresentable` の中身を非同期で差し替えても SwiftUI は測り直さない** | SwiftUI が `sizeThatFits` を呼ぶのは中身が空のロード前だけ。あとから `UIHostingController.view` を貼っても枠は伸びず、はみ出して後続コンテンツに重なる（IOS-9 と同じ症状・原因は別）。UIKit 側で実寸を測って `@State` へ返し、`.frame(height:)` を確定させる |

## インフラ (Terraform / GitHub Actions: infra/terraform, .github/workflows)

| # | パターン | 検出観点 |
|---|---|---|
| INFRA-1 | **Cloud Run の予約環境変数を明示指定する** | `PORT` は Cloud Run が `ports.container_port` から自動注入する予約名。`env` で渡すと API が `reserved env names were provided: PORT` で apply/deploy ごと拒否する（`K_SERVICE` 等も同様） |
| INFRA-2 | **値の無い Secret を参照した Cloud Run を作ろうとする** | Secret Manager の「箱」だけ作って値を入れない状態でリビジョンを作ると起動失敗 → `terraform apply` 自体がエラーになる。「箱を作る apply → 値投入 → 本 apply」の順を手順書に書く |
| INFRA-3 | **PR で走る `terraform plan` に書き込み権限のSAを渡す** | plan は PR ブランチの HCL（provider 設定・data source）を CI 上で評価する＝PR の内容が実行される。plan 用は読み取り専用SAに分け、強権限SAは `attribute.job_workflow_ref` で apply ワークフローに限定する |
| INFRA-4 | **WIF の principalSet がコメントより広い** | `attribute.repository/...` はリポジトリ全体（全ブランチ・全ワークフロー）を指す。「main だけ」と書いてあっても実際は絞れていない。ブランチ/ワークフロー限定には対応する attribute を `attribute_mapping` に足す |
| INFRA-5 | **Terraform 管理外リソースへの権限付与漏れ** | state 用 GCS バケットは Terraform 管理外。CI 用SAのプロジェクトロールに GCS 権限が無いと `terraform init` が 403。バケット側 IAM を手順書に含める |

---

## 運用

- レビューは本表をチェックリストとして使う
- 実装時に本表を意識する
- 新規再発は修正後に 1 行追記する
