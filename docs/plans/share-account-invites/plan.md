# plan — share-account-invites（共有のアカウント招待制化）

**状態: 実装着手可**（`questions-requirements.md` Q1〜Q13 回答済み・2026-08-07）。
**Q14 のみ未回答。** 本書は **Q14-a（トークンのディープリンク入口を残す）** 前提で書いてある。
14-b を選ぶ場合は **§11** の差分を適用してから着手する。

契約の正: `api-contract-delta.md`（本ディレクトリ）。要件の正: `requirements.md`。
作成日: 2026-08-07 / 更新: 2026-08-07（Q1=A 確定を反映）/ planner: aidlc-planner

---

## 1. ゴール

共有を「トークン URL を知っていれば誰でも閲覧・編集できる」から
**「招待されたアカウントだけが、ログインした状態で閲覧・編集できる」** に変える。

| 変わること | Before | After |
|---|---|---|
| 認可 | トークンの有効性のみ | **アカウント認可**（`share_recipients`） |
| 公開経路 | `GET/PATCH /public/shares/:token`（認証不要） | **削除** |
| 受け取り側の導線 | トークン URL を個別に受け取る | **アプリ内受信箱**（`GET /v1/shares/received`） |
| `shared_with_account_ids` | 記録用メタ（ACL ではない） | **削除**。`share_recipients` が ACL の実体 |
| 非招待者 | 全部見える | token 経路 403 / id 経路 404 |

### 1.1 ロードマップとの関係

`docs/10-mock-delta-2026-07-31.md` §3 の表が

> Phase 2 | 共同編集。**編集権限をメンバーに限定するか、現状モックどおり「URL 知っていれば編集可」かを再決定**

としている、その**再決定そのもの**が本計画である。決定は「メンバーに限定する（＋公開経路を廃止する）」。

- `docs/09-roadmap.md` に新しい行は追加しない（1-6 / 1-8 の再定義であり、Phase 2「共同編集」の前提整備）
- **`docs/10` §3 の Phase 表 + §4 の「記録用。Phase1ではACLに使わない」を本計画で更新する**（T-DOC / Q13）
- `docs/09-roadmap.md:519` のリスク L3（共有 URL 流出）の緩和策に「招待制（アカウント認可）」を追記する
- **KPI「共有リンク経由の新規インストール比率 ≥ 10%」は Q1=A の決定で導線が消えるため達成不能になる。**
  本計画では扱わず、`docs/09` 側の残課題として T-DOC で記載のみ行う（ユーザー指示）

ロードマップ外の機能は含んでいない（APNs・Universal Links・`permission` 変更 API はいずれもスコープ外として明記済み）。

---

## 2. 影響範囲（層チェックリスト）

| 層 | 対象 | 規模 |
|---|---|---|
| DB | `share_recipients` 新設 / `shared_with_account_ids` 削除 / 全件失効の移行 | 中 |
| BE | `public/` の解体・移設、`shares/` 拡張、`shares/received/` 新設、`app.setup.ts` / `app.module.ts` | **大** |
| iOS Domain | `SharedBoardStore` 改修、`SharedInboxStore` 新設、`AppError` 2 件、token store 削除 | 中 |
| iOS Network | `PublicApiClient` 削除、`RemoteSharedInboxRepository` 新設、board を `ApiClient` へ | 中 |
| iOS Features | `SharedInbox` 新設、`SharedBoard` 改修、`OpenSharedBoardView` 削除、`ShareRecipientsView` 改修 | 中 |
| iOS App | `AppEnvironment` / `DeepLinkRouter` | 小 |
| docs | 03 / 04 / 05 / 09 / **10** / STATUS | 中 |

詳細なファイル一覧は `requirements.md` §7。

---

## 3. エッジケース

`requirements.md` §6（E-1〜E-15）を参照。実装時に特に落としやすいもの:

- **E-1 / E-2**: アカウント削除時の cascade。`docs/plans/account-deletion/` の削除フローに `share_recipients` を含める
- **E-10**: `account_id` はスナップショット、`user_id` が正。招待判定は必ず `user_id` で行う
- **E-14**: 移行で全件失効させるため、既存トークンのディープリンクは全て「この共有は終了しています」になる

---

## 4. 設計判断（採用案 + 却下案）

### D1. 招待は正規化テーブル `share_recipients` で持つ
**採用理由**: 受信箱は「自分が招待されている共有」の逆引きが要る。`user_id` の btree インデックス 1 本で済む。招待ごとの状態（`hidden_at` / `last_viewed_at`）も持てる。
**却下**: `shared_with_account_ids text[]` を ACL に昇格 + GIN。①招待ごとの状態を持てない ②`account_id → user_id` の解決で毎回 `profiles` と結合が要る ③配列要素の削除がアトミックに書きにくい。

### D2. 受け取り側の addressing は `share_id`。token は `redeem` 専用
**採用理由**: 受信箱経由のユーザーは token を持たない。オーナー以外に token（＝ capability）を配り続ける理由が無い。
**却下**: token をそのまま使い続ける。受信箱の各行に token を載せることになり、`GET /v1/shares/received` のレスポンスから capability が漏れる。

### D3. 非招待者への応答は経路で出し分ける（token=403 / id=404）
**採用理由**: F2（「403 で拒否」）はトークン所持者に原因を伝えるための要件。一方 `:id` は招待経由でしか知り得ないので、403 を返すと共有 ID の存在を confirm してしまう。
**却下**: 全部 403 — id の存在露出。全部 404 — 招待漏れのユーザーが原因を特定できず、F2 の意図に反する。

### D4. 公開経路は完全廃止（`visibility` enum を作らない）
**採用理由**: ユーザー決定（Q1=A・2026-08-07）。「基本的にアカウントを持っている人どうしの機能にしたい」というプロダクト方針を KPI 試算より優先。
**却下**: `visibility: "invited_only" | "link"` の 2 値で公開共有を残す（planner の初版提案）。`docs/09` の「共有リンク経由の新規インストール比率 ≥ 10%」を維持できるが、プロダクト方針と合わない。**この案は却下済み。実装に持ち込まないこと。**

### D5. `apps/api/src/public/` はディレクトリごと消さず `shares/board/` へ移設する
**採用理由**: このディレクトリの大半（presenter / item-key / share-write / identity-summary / shared-applications）は**マスキングとペイロード組み立ての中核**で、新しい認証経路がそのまま使う。消して書き直すと同じレスポンスを組み立てる箇所が 2 つに増える（NFR-7）。
**却下**: `public/` を残したまま controller だけ消す。名前が実態と合わず、後続が「まだ公開経路がある」と誤読する。

### D6. 移行は全件失効（backfill しない）
**採用理由**: ユーザー決定（Q9=9-3）。本番未リリースでデータを捨ててよい。`shared_with_account_ids` は ACL ではなかったので、招待へ昇格させると「記録用に書いただけの ID」に権限を与えてしまう。
**却下**: `shared_with_account_ids` を `share_recipients` へ backfill。上記の権限誤付与リスクがある。

### D7. 受け取り側の HTTP クライアントは `ApiClient` に統一（`PublicApiClient` は削除）
**採用理由**: 認証必須になった以上、401 → refresh → 失敗 → ログアウトは自分のセッションに対する想定どおりの挙動。`PublicApiClient` の存在理由（「他人の共有を開いただけでログアウトさせない」）が消滅した。
**却下**: `PublicApiClient` に Bearer を足す。設計意図が二重になり、どちらを使うべきかが判断できなくなる。

### D8. `item_key` / `rev` の HMAC 鍵は `token_hash` のまま
**採用理由**: 鍵はサーバー内部にあり、addressing の変更と独立に保てる。`share-item-key.ts` / `share-write.ts` とその spec を壊さずに済む。
**却下**: 鍵を `share_id` に変更。既存テストが全て書き換えになるが得るものが無い。

### D9. `POST /v1/shares` の `url` をカスタムスキームに変える
**採用理由**: `/public/*` 廃止により https の共有 URL は開ける先が無くなる。`meigicho://share/<token>` ならアプリが受け取れる。
**却下**: `url` を削除する。既存レスポンスキーの削除になり、iOS の「リンクをコピー」導線も同時に消す必要がある（＝ Q14-b。§11 参照）。

### D10. 招待判定は `permission` 判定より前に置く
**採用理由**: 逆にすると、非招待者が 403 を受け取ることで「そのリンクは read だ」＝「そのリンクは存在する」を知れてしまう。
**却下**: 既存 `UpdateShareItemUseCase` の順序（permission が先）をそのまま維持。上記の情報漏洩が残る。

---

## 5. タスク分解

**担当エージェントとモデルは `.claude/rules/02-agents.md` のエスカレーション基準に従う。**

### Wave 0 — BE 基盤（**直列・単独実行** / nest-developer, model: **opus**）

#### T1. スキーマ・エラーコード・移行・モジュール枠
- `schema.prisma`: `ShareRecipient` 新設 / `ShareLink.sharedWithAccountIds` 削除 / `recipients` リレーション / `User.shareRecipients`
- `cd apps/api && npx prisma db push`（**必ず `apps/api/` で** — BE-5）
- `error-codes.ts`: `SHARE_NOT_INVITED`(403) / `SHARE_RECIPIENT_UNKNOWN`(400) / `SHARE_RECIPIENT_SELF`(400)。`AllExceptionsFilter` の写像を spec で確認（BE-6）
- 移行: `update share_links set revoked_at = now() where revoked_at is null;`（冪等。**純粋関数に切り出して spec を書く**）
- 空モジュール枠を作る: `shares/board/share-board.module.ts` / `shares/received/shares-received.module.ts`
- `app.module.ts`: `PublicModule` を外し上記 2 つを登録（**このファイルは T1 のみが触る**）
- **テスト**: error-codes 写像・移行の冪等性

### Wave 1 — BE 解体・移設（**直列・T1 の直後 / 単独実行** / nest-developer, model: sonnet）

#### T2. 公開経路の削除と `shares/board/` への移設
**これは「移動 + 削除」であり、振る舞いを増やさない。** 先にやる理由: T3〜T5 が最終パス上に実装できるようにするため。

- 削除: `public/public.controller.ts` / `public/public.module.ts` / `ROBOTS_TAG_*`
- 移設（`api-contract-delta.md` §5 の表のとおり。**中身は変えない**）: `public/` の残り 8 ファイル + 対応 spec → `shares/board/`
- `app.setup.ts`: `GLOBAL_PREFIX_EXCLUDE` から `public/shares/*` の 2 行を削除（**`health` / `readyz` / webhook を巻き添えにしない**）
- `ThrottleShareWrite` のカウント単位を token → userId + share_id へ
- **完了条件**: 既存の移設済み spec が**そのまま緑**（振る舞いを変えていない証明）+ `/public/shares/x` が 404

### Wave 2 — BE 実装（**並列 2 本** / nest-developer, model: sonnet）

#### T3. オーナー側の招待（`shares/`）
Red 先行: **AC-SI-01〜13**
- `create-share.dto.ts`: `shared_with_account_ids` を必須化（1〜20）
- `share-recipients.service.ts`（新規）: 実在確認（`profiles.accountId` 一括 `findMany`）/ 作成 / 追加 / 削除 / `isRecipient(shareLinkId, userId)`
- `create-share.use-case.ts`: 判定順序（DTO → self → 実在 → PLAN_LIMIT_SHARE → PLAN_LIMIT_SHARE_WRITE → 作成）を 1 TX で
- `add-recipients.use-case.ts` / `remove-recipient.use-case.ts`（新規）
- `shares.presenter.ts`: `recipients` を返す（`hidden_at` は返さない）。`shared_with_account_ids` 削除
- `shares.service.ts`: `sharedWithAccountIds` の書き込み削除
- `shares.controller.ts`: recipients 2 ルート + レート制限
- `url` をカスタムスキームへ（D9。組み立て箇所を grep して 1 箇所に集約）

#### T4. 受信箱・board 読み取り（`shares/received/` + `shares/board/`）
Red 先行: **AC-SI-20〜28、AC-SI-40〜47**
- `shares/received/`: controller + use-cases（`list-inbox` / `get-board` / `redeem` / `set-hidden`）
- `shares/board/use-cases/resolve-share.use-case.ts`: token 起点 → `ShareLink` 起点へ。招待判定を §4.2 の順序で挿入
- `share_recipients.last_viewed_at` 更新（オーナー閲覧では更新しない）
- **マスキングを再実装しない。`public-share.presenter.ts`（移設済み）を使う**（NFR-7）
- **`update-share-item.use-case.ts` は触らない**（T5 の所有）

### Wave 3 — BE 書き込み（**直列・T4 の後** / nest-developer, model: **opus**）

#### T5. `PATCH /v1/shares/received/:id/items/:item_key`
Red 先行: **AC-SI-29**
- `shares/board/use-cases/update-share-item.use-case.ts` を token 起点 → `ShareLink` 起点へ分解
- **判定順序に招待判定を ② として挿入**（`permission` 判定より前 — D10）
- 既存の判定順序コメント（旧 `update-share-item.use-case.ts:27-37`）を**新しい表に書き換える**。古いコメントが残ると後続が誤読する
- `shares/received/` のコントローラにルートを追加
- **依存**: T4 が `shares/received/` の構成を確定した後（同一ディレクトリ）

> **ここで API 契約が実装として確定する。iOS はこの後に発行する。**

### Wave 4 — iOS 基盤（**直列・単独実行** / swift-developer, model: **opus**）

#### T6. Domain + AppRoute の確定
- `Domain/Models`: `ShareRecipient` / `SharedInboxItem`
- `Domain/Repositories`: `SharedInboxRepository` protocol / `ShareRepository` に `addRecipients` / `removeRecipient`
- `Domain/AppError.swift`: `.shareNotInvited` / `.shareRecipientUnknown(accountIDs:)` + `userMessage`
- `Domain/SharedBoardStore.swift`: `SavedSharedBoard` / `SharedBoardTokenStoring` を削除。Store を `open(shareID:)` / `redeem(token:)` 起点へ。**`SharedBoardLink`（純粋パーサ）は残す**（Q14-a）
- `Domain/SharedInboxStore.swift`（新規）
- `Features/Navigation/AppRoute.swift`: `.sharedInbox` / `.sharedBoard(shareID:)`（`.sharedBoard(token:)` を置換）
- `Domain/Tests/.../SharedBoardStoreTests.swift`: token store 関連を削除、`SharedBoardLink` のテストは残す
- **`Domain/Tests/.../AdGatekeeperTests.swift:146` から `OpenSharedBoardView.swift` の名指しを削除**（NFR-8）
- **完了条件**: `xcodebuild` BUILD SUCCEEDED + Domain の `swift test` 全緑

### Wave 5 — iOS 実装（**並列 4 本** / swift-developer, model: sonnet）

#### T7. Network
- `PublicApiClient.swift` / `SharedBoardTokenStore.swift` を**削除**
- `RemoteSharedInboxRepository.swift`（新規・`ApiClient`）
- `RemoteSharedBoardRepository.swift`: `ApiClient` + shareID 起点へ
- `RemoteShareRepository.swift`: recipients 2 メソッド + `SHARE_RECIPIENT_UNKNOWN` の details 格上げ（**このファイルだけが details の形を知る**）
- DTO: `recipients` / inbox / redeem。`shared_with_account_ids` のパース削除
- `ApiClient.swift` / `Endpoint.swift` のコメント・ガードを整理（`api-contract-delta.md` §6.1 の表を全部潰す）
- `Network/Tests/`: `ResponseValidatorTests` / `RemoteSharedBoardRepositoryTests` を追従

#### T8. 受信箱画面（`Features/SharedInbox/`）
- 一覧 / 空状態 / エラー / 未読バッジ / 非表示スワイプ
- **到達経路を必ず配線する**（IOS-1 / IOS-3）。ホームまたは設定から 1 タップで開けること
- Repository は protocol でモックして先行実装できる

#### T9. board 改修（`Features/SharedBoard/`）
- `SharedBoardView`: shareID 起点・未招待（403/404）の表示分岐（AC-SI-72-M）
- `OpenSharedBoardView.swift` を**削除**
- **`HomeView.swift:97` の提示元を削除**（IOS-1。放置すると死んだシートが残る）
- **`DesignSystem/Tests/.../AdSlotForbiddenScreensTests.swift:20` から名指しを削除**（NFR-8）

#### T10. オーナー側 UI（`Features/Share/`）
- `ShareRecipientsView`: 招待を必須化（0 件で発行ボタン無効）・**`:133` の「アクセス制限ではなく記録用」文言を削除**して「ここに入れたアカウントだけが見られます」へ・発行後の招待追加削除 UI
- `AccountIDValidator` は既存流用（**形式チェックのみ**。実在確認はサーバー — IOS-4）
- 「リンクをコピー」はカスタムスキームの URL を配る形に（D9）

### Wave 6 — iOS 配線（**直列・単独実行** / swift-developer, model: sonnet）

#### T11. Composition Root + ディープリンク
- `AppEnvironment.swift`: `publicApiClient` / `sharedBoardTokenStore` を削除、`sharedInboxRepository` を注入
- `DeepLinkRouter.swift`: token → `redeem` → shareID 遷移。**未ログイン時は保留トークンを保持してサインイン後に再試行**（FR-4-3）
- **依存**: T7 + T8 + T9 が揃ってから

### Wave 7 — docs + レビュー（直列）

#### T12. docs 更新
- `docs/04-api.md` §3.7 / `docs/03-database.md` §4.9 / `docs/05-ios-client.md`
- **`docs/10-mock-delta-2026-07-31.md` §3 / §4**（Q13・本計画の必須成果物）※ 本計画で先行実施済み
- `docs/09-roadmap.md` L3 の緩和策 + KPI の残課題
- `CLAUDE.md` の「既知の未整備」/ `docs/plans/STATUS.md`

#### T13. code-reviewer（**別セッション**・model: opus）

---

## 6. 並列実行可能なタスク

```
Wave 0 【直列・単独】  T1  schema / error-codes / 移行 / module 枠
                        ↓
Wave 1 【直列・単独】  T2  public 解体・shares/board へ移設
                        ↓
Wave 2 【並列 2 本】   T3 (shares/)  ┃  T4 (shares/received/ + board 読み取り)
                        ↓
Wave 3 【直列】        T5  PATCH（招待判定を permission より前へ）
                        ↓
        ===== API 契約が実装として確定。ここまで BE を緑にしてから iOS へ =====
                        ↓
Wave 4 【直列・単独】  T6  iOS Domain + AppRoute
                        ↓
Wave 5 【並列 4 本】   T7 (Network) ┃ T8 (SharedInbox) ┃ T9 (SharedBoard) ┃ T10 (Share)
                        ↓
Wave 6 【直列・単独】  T11 AppEnvironment / DeepLinkRouter
                        ↓
Wave 7 【直列】        T12 docs  →  T13 code-reviewer（別セッション）
```

### 並列で走らせてはいけない組み合わせ

| 組み合わせ | 理由 |
|---|---|
| T1 と何か | `schema.prisma` / `app.module.ts` / `error-codes.ts` を単独所有 |
| T2 と T3/T4/T5 | T2 がファイルを移動する。移動中に別エージェントが同ファイルを編集すると衝突する |
| T4 と T5 | `shares/received/` のコントローラと `shares/board/use-cases/` を共有 |
| T6 と何か | `AppRoute.swift` と Domain 全体を単独所有 |
| T11 と何か | `AppEnvironment.swift`（Composition Root） |
| **BE 未完了のまま iOS 全般** | 判定順序・キー名がズレると iOS が黙って壊れる（IOS-2）。`.claude/rules/03-parallel-development.md`「API 契約未確定のまま BE と iOS を同時走らせない」 |

### 工数の目安（planner 見積・参考値）

| Wave | 内容 | 目安 |
|---|---|---|
| 0〜1 | schema + 解体移設 | 1.0 人日 |
| 2〜3 | BE 実装（招待 / 受信箱 / PATCH） | 2.5 人日 |
| 4〜6 | iOS（Domain + 4 並列 + 配線） | 2.5 人日 |
| 7 | docs + レビュー + 修正 | 1.0 人日 |
| | **合計** | **≈ 7.0 人日** |

---

## 7. ファイル所有表（同時に触らせない）

| ファイル / ディレクトリ | 所有 | 以後 |
|---|---|---|
| `apps/api/prisma/schema.prisma` | **T1 のみ** | 読み取り専用 |
| `apps/api/src/app.module.ts` | **T1 →（順に）T2** ※両方とも直列・単独実行なので衝突しない。T1 が新モジュールを登録し、T2 が `PublicModule` を外す | Wave 2 以降は読み取り専用 |
| `apps/api/src/common/errors/error-codes.ts` | **T1 のみ** | 読み取り専用 |
| `apps/api/src/app.setup.ts` | **T2 のみ** | 読み取り専用 |
| `apps/api/src/public/**` | **T2 のみ**（削除・移設） | 消滅 |
| `apps/api/src/shares/board/**` | T2 が作成 → T4（resolve）/ T5（update）が改修 | 分担は use-case 単位 |
| `apps/api/src/shares/*.ts`（dto / service / presenter / controller / use-cases） | **T3 のみ** | — |
| `apps/api/src/shares/share-validity.ts` | 誰も編集しない | 読み取り専用 |
| `apps/api/src/shares/received/**` | T4 が作成 → T5 がルート追加 | 直列 |
| `apps/api/src/common/throttling/**` | **T2 のみ** | 読み取り専用 |
| `meigicho/Packages/Domain/**` | **T6 のみ** | 以後読み取り専用 |
| `meigicho/Packages/Features/.../Navigation/AppRoute.swift` | **T6 のみ** | 以後読み取り専用 |
| `meigicho/Packages/Network/**` | **T7 のみ** | — |
| `meigicho/Packages/Features/.../SharedInbox/**` | **T8 のみ** | — |
| `meigicho/Packages/Features/.../SharedBoard/**`, `Home/HomeView.swift`, `DesignSystem/Tests/**` | **T9 のみ** | — |
| `meigicho/Packages/Features/.../Share/**` | **T10 のみ** | — |
| `meigicho/App/**` | **T11 のみ** | — |
| `meigicho/project.yml` | 原則変更不要（新規ファイルは既存ディレクトリ配下）。触ったら **`xcodegen generate` 必須**（IOS-8） | — |

**注意**: `AdGatekeeperTests.swift`（Domain）は T6、`AdSlotForbiddenScreensTests.swift`（DesignSystem）は T9 が持つ。
**どちらも `OpenSharedBoardView.swift` を名指ししているので、片方だけ直すとテストが落ちる。**

---

## 8. 受入基準 → テストケース

### 8.1 BE（`apps/api` / jest。**テスト先行 Red → Green**）

| AC-ID | テストファイル | テスト名の骨子 |
|---|---|---|
| AC-SI-01, 05, 07 | `shares/dto/create-share.dto.spec.ts` | 空配列 400 / 小文字 400 / 21 件 400 |
| AC-SI-02, 04, 06 | `shares/share-recipients.service.spec.ts` | 未知 ID で 400 + `unknown_account_ids` / 重複排除 / self 400 |
| AC-SI-03, 13 | `shares/use-cases/create-share.use-case.spec.ts` | recipients 行が userId 解決済みで作られる / **未知 ID が PLAN_LIMIT より先に返る** |
| AC-SI-08〜12 | `shares/use-cases/add-recipients.use-case.spec.ts` / `remove-recipient.use-case.spec.ts` | 追加は既存を消さない・冪等 / 未知 ACC-ID の削除も 204 / 他人の id 404 / 失効 id 404 / 最後の 1 人も 204 |
| AC-SI-20〜24 | `shares/received/use-cases/get-board.use-case.spec.ts` | 招待済み 200 / **非招待 404 SHARE_INVALID** / 401 / オーナー 200 / 失効・期限切れ・未知が同一 404 |
| AC-SI-25〜27 | `shares/received/use-cases/redeem.use-case.spec.ts` | 招待済み 200 / **非招待 403 SHARE_NOT_INVITED** / 未知・失効・期限切れ 404 |
| AC-SI-28, 29 | `shares/board/use-cases/update-share-item.use-case.spec.ts` | 招待削除後 404 / **read リンクに非招待者 → 403 ではなく 404**（招待判定が先） |
| AC-SI-30〜32 | `app.setup.spec.ts` + controller spec | `/public/shares/:token` が 404 / `/v1/public/shares/:token` が 404 / `GLOBAL_PREFIX_EXCLUDE` に health・readyz が残っている |
| AC-SI-40〜47 | `shares/received/use-cases/list-inbox.use-case.spec.ts` | 有効のみ / 失効除外 / 自分発行除外 / 非表示除外 / キー集合 / **禁止キー不在** / 空 200 / `last_viewed_at` 更新 |
| AC-SI-60〜62 | 移行スクリプトの spec | 全件 revoked / 既存 `revoked_at` を上書きしない（冪等） |

**AC-SI-21（id → 404）と AC-SI-26（token → 403）のテストは必ずセットで書く。**
この 2 つが本計画の核心で、取り違えると情報漏洩か UX 崩壊のどちらかになる。

**AC-SI-45（禁止キー不在）は「あるべきキーの検証」ではなく「あってはならないキーの不在」で書く**
（`expect(Object.keys(item)).toEqual([...])` の形。追加漏れではなく**混入**を検出したいため）。

### 8.2 iOS Domain / Network（`swift test`）

| 対象 | 検証 |
|---|---|
| `AppError` | `SHARE_NOT_INVITED` / `SHARE_RECIPIENT_UNKNOWN` の envelope → `AppError` 写し。**`details` が読めないときは格上げしない** |
| `SharedBoardLink` | 既存テスト（`SharedBoardStoreTests.swift:14-39`）を**そのまま維持**（Q14-a） |
| `SharedInboxStore` | 一覧取得 / 非表示 / エラー時に既存表示を消さない |
| `SharedBoardStore` | shareID 起点での open / `.shareNotInvited` の扱い / 409 競合の既存挙動を壊していない |
| `RemoteSharedInboxRepository` | パス・メソッド・DTO デコード |

### 8.3 iOS UI（機械ゲートは `xcodebuild` BUILD SUCCEEDED のみ）

`requirements.md` §5.5（AC-SI-70-M〜77-M）を §9 の手順で確認する。

---

## 9. 手動確認手順（**2 アカウント必要**）

前提: アカウント A（オーナー）・B（招待先）・C（無関係）でサインインできる端末 / シミュレータ。

| # | 手順 | 期待（AC） |
|---|---|---|
| 1 | A で申込一覧 → ツアーを共有。ACC-ID を**空のまま**発行しようとする | 発行ボタンが無効（AC-SI-74-M） |
| 2 | A で存在しない ACC-ID を入力して発行 | 「見つからないアカウント ID があります: ACC-…」（AC-SI-02） |
| 3 | A で B の ACC-ID を入力して発行 | 「記録用」文言が無い。発行成功（AC-SI-74-M） |
| 4 | B でアプリを開き受信箱を見る | A の共有が 1 件出る。未読バッジ（AC-SI-70-M / F1） |
| 5 | B で行をタップ | board が開く。read なら編集 UI 無し / write なら状況を変更できる（AC-SI-71-M） |
| 6 | 5 の直後に B のホームへ戻る | **B が自分のアカウントからログアウトされていない**（AC-SI-76-M / IOS-6） |
| 7 | A が発行時にコピーしたリンクを C で開く | 「この共有はあなたに共有されていません」。中身は一切出ない（AC-SI-72-M / F2） |
| 8 | 未ログイン状態で同じリンクを開く | サインイン導線 → サインイン後に自動で board へ（AC-SI-73-M） |
| 9 | A で B の招待を削除 → B が受信箱を引き直す | B の受信箱から消える（AC-SI-75-M） |
| 10 | B が受信箱の行をスワイプして非表示 → A の共有一覧を見る | B の受信箱から消え、**A 側には非表示の事実が出ない**（Q3） |
| 11 | ホーム画面を一通り操作 | 「共有リンクを開く」シートが存在しない（AC-SI-77-M） |

---

## 10. 検証ゲート

BE（`CLAUDE.md` の SSOT）:
```bash
cd apps/api && npx tsc --noEmit
cd apps/api && npm test
cd apps/api && npm run build
```

iOS:
```bash
xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/meigicho-build CODE_SIGNING_ALLOWED=NO build
```
加えて `Domain` / `Network` / `DesignSystem` パッケージの `swift test`。

**標準ゲートで検出できない、タスク固有の検証**:

1. `schema.prisma` 変更後に `npx prisma db push` を **`apps/api/` で**実行済みか（BE-5）
2. `/public/shares/x` と `/v1/public/shares/x` が**両方 404** になるか（AC-SI-30 / 32）
3. `GLOBAL_PREFIX_EXCLUDE` に `health` / `readyz` が残っているか（巻き添え削除の検出）
4. T2 完了時点で**移設した既存 spec がそのまま緑**か（振る舞いを変えていない証明）
5. iOS で新ファイルを足したら `xcodegen generate` を実行したか（IOS-8）
6. 受信箱画面への到達経路が配線されているか（IOS-1 / IOS-3）
7. `grep -rn "shared_with_account_ids\|PublicApiClient\|OpenSharedBoardView\|SavedSharedBoard" apps/api/src meigicho/App meigicho/Packages/*/Sources meigicho/Packages/*/Tests` が**ヒット 0**（削除の取りこぼし検出）

---

## 11. Q14-b を選ぶ場合の差分

Q14 で **14-b（トークン URL の入口を完全に消す）** が選ばれた場合、以下だけを変更すれば足りる。

| 対象 | 変更 |
|---|---|
| `api-contract-delta.md` §4.4 | `POST /v1/shares/received/redeem` を**削除**。§0.1 の `SHARE_NOT_INVITED` も削除 |
| `api-contract-delta.md` §1 | レスポンスから `token` / `url` を削除（D9 も不要になる） |
| `requirements.md` FR-4 | 節ごと削除。**F2（403）は「サーバー内部の防御としてのみ存在」ではなく「要件として消滅」と明記する**（ユーザー確定要件の取り下げになるため、明示的な合意が要る） |
| AC-SI-25〜27 / AC-SI-72-M / AC-SI-73-M | 削除 |
| T6 | `SharedBoardLink` も削除。`SharedBoardStoreTests.swift:14-39` も削除 |
| T7 | `redeem` メソッドを作らない |
| T10 | 「リンクをコピー」ボタンを削除 |
| T11 | `DeepLinkRouter` から `share` ホストの処理を削除（Google Sign-In の callback 処理は残す） |

**14-b は F2（ユーザーが最初に挙げた確定要件の 1 つ）を実質的に無効化する。** 選ぶ場合はその点の合意を取ること。

---

## 12. リスク

| # | リスク | 対応 |
|---|---|---|
| R1 | `public/` を「公開経路だから」と丸ごと削除され、マスキングロジックが失われる | D5 と `api-contract-delta.md` §5 の「削除してはいけないもの」表で明示。T2 の完了条件を「移設済み spec がそのまま緑」にした |
| R2 | `GLOBAL_PREFIX_EXCLUDE` の編集で `health` / `readyz` / webhook を巻き添えにする | §10 の検証 3 と AC-SI-32 |
| R3 | 招待判定を `permission` 判定の後ろに置く | D10 + AC-SI-29 のテスト |
| R4 | 403 / 404 の出し分けを実装者が「統一した方が綺麗」と揃える | 契約 §4.2 / §4.3 / §4.4 の判定順序表 + AC-SI-21 / AC-SI-26 のセットテスト |
| R5 | `OpenSharedBoardView` 削除で広告禁止画面リストのテストが落ちる | §7 の注意書き + NFR-8 + §10 の検証 7 |
| R6 | `PublicApiClient` の設計意図コメントを読んだ実装者が古い前提で判断する | `api-contract-delta.md` §6.1 に参照元の file:line 表を作った。T7 の完了条件に含める |
| R7 | 受信箱の N+1 | `share_recipients.userId` インデックス + tour 名の一括解決（既存 `SharesService.tourNames` と同手法） |
| R8 | `share_recipients` の cascade が `docs/plans/account-deletion/` と矛盾 | T1 で `docs/plans/account-deletion/` を読み、削除フローに `share_recipients` を含める（E-1） |
| R9 | 移行で全件失効させた結果、テスト用に手で作った共有も消える | 意図どおり（Q9=9-3）。開発者は作り直す |

---

## 13. ハンドオフ（委譲プロンプト案）

`.claude/rules/06-delegation-prompts.md` の 7 要素に従う。**サブエージェントは会話コンテキストゼロで起動する。絶対パス・決定事項・制約を指示文に書き写すこと。**

### 13.1 T1（nest-developer, model: **opus**）

```
まず /Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md を読み従うこと。

【目的/背景】共有機能を「トークンURLを知っていれば誰でも」から「招待されたアカウントだけ」に変える計画の
基盤（DBスキーマ・エラーコード・既存データ移行・モジュール枠）を作る。後続の T2〜T5 がこの上に実装するため、
ここで確定した型・列名を後から変えない。

【対象】/Users/yuyamorishita/オタ活アプリ/apps/api/

【契約の正】/Users/yuyamorishita/オタ活アプリ/docs/plans/share-account-invites/api-contract-delta.md
 - §0.4 に schema 定義がそのまま書いてある。これを写すこと
 - §0.1 がエラーコード、§0.5 が移行SQL
要件: 同ディレクトリ requirements.md（FR-5 / AC-SI-60〜62）

【やること】
1. apps/api/prisma/schema.prisma を api-contract-delta.md §0.4 のとおりに変更する。
   - ShareRecipient モデル新設（@@unique([shareLinkId, accountId]) と @@index([userId]) を必ず入れる）
   - ShareLink.sharedWithAccountIds を **削除**する
   - ShareLink に recipients ShareRecipient[]、User に shareRecipients ShareRecipient[] を追加
   - **visibility という列は作らない**（計画初版に提案があったが却下済み）
2. `cd /Users/yuyamorishita/オタ活アプリ/apps/api && npx prisma db push` を実行する（必ず apps/api/ で）。
3. src/common/errors/error-codes.ts に SHARE_NOT_INVITED(403) / SHARE_RECIPIENT_UNKNOWN(400) /
   SHARE_RECIPIENT_SELF(400) を追加し、AllExceptionsFilter が正しい HTTP に写すことを spec で確認する。
4. 既存 share_links を全件失効させる移行処理を書く（api-contract-delta.md §0.5）。
   **冪等性（2回実行しても既存の revoked_at を上書きしない）を純粋関数に切り出して spec を書く**。
5. 空のモジュール枠を作り app.module.ts に登録する:
   src/shares/board/share-board.module.ts と src/shares/received/shares-received.module.ts。
   **PublicModule はこの時点ではまだ外さない**（T2 が public/ を解体するまで動かす必要があるため）。

【従うべき既存例】
- schema: apps/api/prisma/schema.prisma:231-252（ShareLink の現在形）
- エラーコード: apps/api/src/common/errors/error-codes.ts
- 移行の書き方に前例は無い。純粋関数 + spec の形にすること

【制約・やらないこと】
- 招待判定ロジック・新エンドポイントの実装（T3/T4/T5 の担当）
- public/ ディレクトリの削除・移設（T2 の担当。**触らないこと**）
- app.setup.ts の GLOBAL_PREFIX_EXCLUDE（T2 の担当）
- /Users/yuyamorishita/オタ活アプリ/.claude/rules/feedback_review_patterns.md の
  BE-1（UUID）/ BE-5（prisma は apps/api/ で実行）/ BE-6（Prisma例外の envelope）に注意

【完了条件】
cd /Users/yuyamorishita/オタ活アプリ/apps/api && npx tsc --noEmit && npm test && npm run build が全て緑。

【報告フォーマット】日本語。①変更ファイル（file:line）②実行した検証コマンドと結果 ③残課題。
```

### 13.2 T2（nest-developer, model: sonnet）

```
まず /Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md を読み従うこと。

【目的/背景】共有の招待制化に伴い、認証不要の公開経路 GET/PATCH /public/shares/:token を廃止する。
ただし apps/api/src/public/ の大半は「公開経路」ではなく**ペイロード組み立てとマスキングの中核**であり、
新しい認証必須経路（後続タスク）がそのまま使う。**このタスクは「移動 + 削除」であり、振る舞いを一切変えない。**

【対象】/Users/yuyamorishita/オタ活アプリ/apps/api/src/public/ , .../src/shares/board/ , .../src/app.setup.ts

【契約の正】/Users/yuyamorishita/オタ活アプリ/docs/plans/share-account-invites/api-contract-delta.md §5
 §5 に「削除するもの」と「削除してはいけないもの（移設先つき）」の表がある。**この表が全て**。

【やること】
1. 削除: public/public.controller.ts, public/public.module.ts, ROBOTS_TAG_HEADER/ROBOTS_TAG_VALUE の export
2. 移設（中身は変えない。import パスだけ直す）: §5 の表にある 8 ファイル + 対応する *.spec.ts を
   apps/api/src/shares/board/ 配下へ。use-cases / dto のサブディレクトリ構造は維持する
3. app.module.ts から PublicModule を外す
4. app.setup.ts の GLOBAL_PREFIX_EXCLUDE から 'public/shares/:token' と
   'public/shares/:token/items/:item_key' の 2 行だけを削除する。
   **'health' と 'readyz' は絶対に消さない**（消すとヘルスチェックが /v1/health に移動して Cloud Run が落ちる）
5. common/throttling の ThrottleShareWrite のカウント単位を token → userId + share_id に変える
   （token がリクエストに現れなくなるため）

【完了条件（このタスク特有・重要）】
- 移設した既存 *.spec.ts が**書き換えなしでそのまま緑**であること（＝振る舞いを変えていない証明）
- GET /public/shares/:token と GET /v1/public/shares/:token が**両方 404**（app.setup.spec.ts で検証）
- GLOBAL_PREFIX_EXCLUDE に health / readyz が残っている（同 spec で検証）
- cd /Users/yuyamorishita/オタ活アプリ/apps/api && npx tsc --noEmit && npm test && npm run build が全緑

【制約・やらないこと】
- 招待判定の追加、resolve-share / update-share-item のロジック変更（T4/T5 の担当）
- schema.prisma / error-codes.ts / app.module.ts の登録内容以外の変更（T1 の所有）

【報告フォーマット】日本語。①移動したファイルの対応表 ②削除したファイル ③検証コマンドと結果 ④残課題。
```

### 13.3 T3 / T4（nest-developer, model: sonnet。**同一メッセージで並列発行**）

両方に共通して書くこと:

- 冒頭に「まず `.claude/skills/implementing-robustly/SKILL.md` を読み従う」
- **「受入基準を失敗する `*.spec.ts` に翻訳してから実装する（Red→Green）」** と §8.1 の該当行を貼る
- `api-contract-delta.md` の該当節（T3 → §1〜§3 / T4 → §4.1・§4.2・§4.4・§4.5）を**全文貼る**
- §7 のファイル所有表から自分の行だけを抜き出して貼り、**「これ以外を編集しない」**と書く
- 既存例の file:line: `apps/api/src/shares/shares.service.ts:44-63`（create の書き方）、
  `apps/api/src/shares/use-cases/create-share.use-case.ts`（use-case の分担）
- `feedback_review_patterns.md` の **BE-2（enum の黙殺フォールバック）・BE-3（レイヤ違反）・BE-4（ownerId スコープ漏れ）**

T4 にのみ追記:
- **「マスキングを再実装しない。T2 が移設した `shares/board/public-share.presenter.ts` を使う」**
- **「`update-share-item.use-case.ts` は触らない（T5 の所有）」**
- 「`GET /v1/shares/received` のレスポンスは、**あってはならないキーの不在**を検証する spec を書く（AC-SI-45）」

### 13.4 T5（nest-developer, model: **opus**）

```
【目的/背景】共有先による軽量編集 PATCH を、認証不要の token 経路から認証必須の share_id 経路へ移し、
**招待判定を permission 判定より前に**挿入する。判定順序がこのタスクの成果物そのものである。

【契約の正】/Users/yuyamorishita/オタ活アプリ/docs/plans/share-account-invites/api-contract-delta.md §4.3
 判定順序の表 ①〜⑧ を**そのままの順で**実装すること。順序を「整理」しないこと。

【特に重要】
招待判定（②）を permission 判定（③）より後ろに置くと、非招待者が 403 を受け取ることで
「そのリンクは read だ」＝「そのリンクは存在する」を知れてしまう。これは本計画が塞ごうとしている穴そのもの。
AC-SI-29 のテスト（read リンクに非招待者 → 403 ではなく 404）を**必ず先に Red で書く**。

【やること】
1. shares/board/use-cases/update-share-item.use-case.ts を token 起点 → ShareLink 起点へ分解する
2. 判定順序に招待判定を ② として挿入する
3. **ファイル冒頭の既存の判定順序コメント（現在 ①〜⑦ が書かれている）を新しい表に書き換える。**
   古いコメントを残すと後続の実装者・レビュアーが誤読する
4. shares/received/ のコントローラに PATCH ルートを追加する（レート制限は userId + share_id 単位）

【やらないこと】public/ の移設（T2 完了済み）、受信箱一覧・redeem（T4 完了済み）

【完了条件】cd /Users/yuyamorishita/オタ活アプリ/apps/api && npx tsc --noEmit && npm test && npm run build 全緑。
【報告】日本語。①変更ファイル(file:line) ②判定順序の実装箇所 ③検証結果 ④残課題。
```

### 13.5 T6（swift-developer, model: **opus**）

```
まず /Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md を読み従うこと。

【目的/背景】共有のアカウント招待制化に伴う iOS 側の Domain 型・Repository protocol・AppRoute を確定する。
以後 T7〜T10 が並列でこの上に実装するため、ここで決めた型を後から変えない。

【対象】/Users/yuyamorishita/オタ活アプリ/meigicho/Packages/Domain/ と
       .../meigicho/Packages/Features/Sources/Features/Navigation/AppRoute.swift

【契約の正】/Users/yuyamorishita/オタ活アプリ/docs/plans/share-account-invites/api-contract-delta.md §6

【重要な前提反転（必読）】
Domain/SharedBoardStore.swift と Network/PublicApiClient.swift は
「共有リンクを受け取った人は自分のアカウントでログインしていない前提」「公開経路の 401 で
自分のアカウントをログアウトさせてはならない（R7 / AC-SB-13-M）」を設計意図としてコメントで明文化している。
**この前提は本変更で完全に消滅する。** 受け取り側は必ずログイン済みになり、board は ApiClient(Bearer) で開く。
古いコメントをそのまま残さないこと（残すと後続が古い前提で判断する — IOS-2）。

【やること】
1. Domain/Models に ShareRecipient / SharedInboxItem を追加
2. Domain/Repositories に SharedInboxRepository protocol、ShareRepository に addRecipients / removeRecipient
3. Domain/AppError.swift に .shareNotInvited と .shareRecipientUnknown(accountIDs:) + userMessage
4. Domain/SharedBoardStore.swift から SavedSharedBoard / SharedBoardTokenStoring を削除。
   Store を open(shareID:) / redeem(token:) 起点へ。
   **SharedBoardLink（URL から token を取り出す純粋パーサ）は残すこと**（ディープリンクで使う）
5. Domain/SharedInboxStore.swift を新規作成
6. AppRoute.swift に .sharedInbox を追加し、.sharedBoard(token:) を .sharedBoard(shareID:) に置換
7. Domain/Tests/DomainTests/SharedBoardStoreTests.swift の token store 関連テストを削除。
   **SharedBoardLink のテスト（14〜39 行目）は残す**
8. Domain/Tests/DomainTests/AdGatekeeperTests.swift:146 の
   "Features/Sources/Features/SharedBoard/OpenSharedBoardView.swift" の名指しを削除する
   （この画面は T9 が削除するため。放置するとテストが落ちる）

【制約・やらないこと】
- Network / Features の実装（T7〜T10 の担当）
- Domain に SwiftData / Network を import しない（IOS-5）
- 既存の 409 競合処理（SharedItemSnapshot / shareItemConflict）の挙動を変えない

【完了条件】
xcodebuild -project /Users/yuyamorishita/オタ活アプリ/meigicho/Meigicho.xcodeproj -scheme Meigicho \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/meigicho-build \
  CODE_SIGNING_ALLOWED=NO build が BUILD SUCCEEDED、かつ Domain パッケージの swift test が全緑。

【報告】日本語。①変更ファイル(file:line) ②削除したシンボルと残した理由 ③検証結果 ④残課題。
```

### 13.6 T7〜T10（swift-developer, model: sonnet。**同一メッセージで 4 本並列発行**）

各プロンプトに必ず含めること:

- `api-contract-delta.md` §6（マッピング表）と §6.1〜§6.3
- §7 のファイル所有表から自分の行だけを抜き出し、**「これ以外を編集しない」**
- `feedback_review_patterns.md` の該当番号:
  - T7 → **IOS-2**（API 契約のパース追従漏れ）・**IOS-5**（依存の逆流）
  - T8 → **IOS-1**（未接続 View のデッドコード化）・**IOS-3**（UI だけ在って配線が無い）
  - T9 → **IOS-1**・**IOS-9 / IOS-10**（既存の広告スロットに触る場合）
  - T10 → **IOS-4**（仕様にない入力制約。実在確認はサーバー。クライアントで公演数を数えない）
- T9 には「`HomeView.swift:97` の提示元と `DesignSystem/Tests/.../AdSlotForbiddenScreensTests.swift:20` の
  名指しを**同時に**消すこと。片方だけだとテストが落ちるか死んだシートが残る」を明記
- 完了条件は `xcodebuild` BUILD SUCCEEDED + 該当パッケージの `swift test`

### 13.7 T11（swift-developer, model: sonnet）

`AppEnvironment.swift` の削除対象を file:line で指定する（`:27` `publicApiClient` / `:43` `sharedBoardTokenStore` /
`:70` / `:117`）。`DeepLinkRouter.swift` は「未ログイン時に保留トークンを持ち、サインイン後に再試行する」を
検証可能な形（`AuthState` の遷移を待つ）で実装させる。**Google Sign-In の callback 処理を壊さない**ことを制約に書く。

### 13.8 T13 code-reviewer（**別セッション**・model: opus）

```
【差分範囲】main...HEAD
【保存先】/Users/yuyamorishita/オタ活アプリ/docs/plans/share-account-invites/review.md
【前提資料】同ディレクトリの requirements.md / api-contract-delta.md / plan.md

【重点観点】
1. 403 SHARE_NOT_INVITED（redeem のみ）と 404 SHARE_INVALID（id 経路）の出し分けが
   api-contract-delta.md §4.2 / §4.3 / §4.4 のとおりか。**SHARE_NOT_INVITED が redeem 以外で使われていないか**
2. PATCH の判定順序で招待判定が permission 判定より前にあるか（§4.3 の表）
3. Guard / ownerId / recipient のスコープ漏れ（BE-4）。他人の share id への読み書き経路が無いか
4. GET /v1/shares/received のレスポンスに token / scope_id / 内部 UUID / 他招待者の ACC-ID が混じっていないか
5. apps/api/src/public/ のマスキングロジックが移設されており、書き直されていないか（同じレスポンスを
   組み立てる箇所が 2 つになっていないか）
6. GLOBAL_PREFIX_EXCLUDE から health / readyz が誤って消えていないか
7. 削除の取りこぼし: grep -rn "shared_with_account_ids|PublicApiClient|OpenSharedBoardView|SavedSharedBoard"
   が apps/api/src と meigicho 配下（.build を除く）で 0 件か
8. feedback_review_patterns.md の BE-1〜6 / IOS-1〜10

【スコープ外（指摘不要）】
APNs・Universal Links・permission の後から変更・招待人数のプラン差別化・
docs/09 の KPI「共有リンク経由の新規インストール比率」の再設定（別途起票済み）
```

---

## 14. 完了の定義

1. `questions-requirements.md` の **Q14** に回答が入り、14-b なら §11 の差分が適用済み
2. BE 検証ゲート 3 コマンドが全緑（新規 spec 含む）
3. iOS `xcodebuild` BUILD SUCCEEDED + Domain / Network / DesignSystem の `swift test` 全緑
4. §10 のタスク固有検証 7 項目が確認済み
5. §9 の手動確認 11 項目が 3 アカウントで確認済み
6. `code-reviewer`（別セッション）で**重大ゼロ**
7. `docs/04` / `docs/03` / `docs/05` / **`docs/10` §3・§4** / `docs/09` L3 / `docs/plans/STATUS.md` が更新済み
