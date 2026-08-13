# コードレビュー — share-account-invites（BE + iOS）

- 対象: `git diff main...work/share-account-invites`（a0aa051 〜 944ccc5、127 ファイル）
- 契約の正: `docs/plans/share-account-invites/api-contract-delta.md`
- レビュー実施: 2026-08-08 / `code-reviewer`（第三者セッション）

## レビュー結果サマリ

- 重大: 1 件（**本レビュー内で修正済み。再検証で重大ゼロを確認**）
- 中: 5 件（うち 2 件を本レビュー内で修正済み）
- 軽微/提案: 4 件

---

## 重大 (Must Fix) — 修正済み

### 1. 受信箱の未読が一度開いても永久に消えない

`apps/api/src/shares/received/use-cases/get-board.use-case.ts:33,49`（修正前）

`unread` の定義は `last_viewed_at IS NULL OR last_viewed_at < share_links.updated_at`
（api-contract-delta.md §4.1）。一方 `GET /v1/shares/received/:id` は

1. リクエスト開始時刻 `now` を取得
2. `ResolveShareUseCase.execute()` → `SharesService.recordView()` が `share_links` を更新
   （Prisma の `@updatedAt` が **その時点の時刻**に進む）
3. `markViewed(shareId, userId, now)` ← **1 で取った古い時刻**を `share_recipients.last_viewed_at` に書く

の順で動くため、常に `last_viewed_at < updated_at` になり、**ボードを開いても未読バッジが落ちない**
（受信箱の中心機能である未読判定が機能しない）。単体では見えず、2 ファイルにまたがる相互作用のバグ。

**修正**: `markViewed` の時刻を `resolveShare` の**後に取り直す**。
再発防止テストを Red → Green で追加（`get-board.use-case.spec.ts` の
「last_viewed_at は ResolveShareUseCase より後の時刻で打つ」）。

---

## 中 (Should Fix)

### 2. 受信箱 DTO が nullable フィールドを非 Optional で受けていた（IOS-2）— 修正済み

- BE: `apps/api/src/shares/received/received-share.presenter.ts:37,53` は
  `scope_name: string | null` / `owner.account_id: string | null`（tour 名を解決できない・
  プロフィール未解決のケース）
- iOS: `SharedInboxDTO.swift` が `scopeName: String` / `accountID: String` で受けていた

→ 1 件でも null が混ざると `GET /v1/shares/received` の**一覧全体がデコード失敗**して受信箱が空になる。

**修正**: Domain / DTO を Optional 化し、表示用フォールバック（`SharedInboxItem.displayTitle`、
`SharedInboxOwner.displayLabel`）を追加。Network に null 許容のテストを追加。

### 3. コールドスタートのディープリンクでログイン済みでもサインインシートが出る — 修正済み

`meigicho/App/DeepLinkRouter.swift:86`（修正前）は `authState == .signedIn` 以外を一律「未ログイン」と
みなしてサインインを促していた。アプリ未起動から `meigicho://share/<token>` を開くと、セッション復帰が
終わる前（`.unknown`）に `onOpenURL` が届くため、**ログイン済みユーザーにもサインインシートが出る**。
その後 `.signedIn` になるとボードがシートの裏で開く。

**修正**: `.unknown` は保留のみ、`.signedOut` になった時点で初めて促す（保留 token は維持）。

### 4. レート制限の実装が 3 通りに分かれている

- `ThrottleShareWrite` — `UserShareThrottlerGuard`（named throttler `share-write`）
- `ThrottleShareInvite`（`apps/api/src/shares/throttle-share-invite.decorator.ts:14-42`）—
  `share-write` バケットを `@Throttle` で上書き流用
- `RedeemThrottlerGuard`（`apps/api/src/shares/received/redeem-throttler.guard.ts:18-40`）—
  `ThrottlerStorage` を**直接叩く手書きガード**

いずれもコメントに「`common/throttling/**` は他タスクの所有物で編集できない」と書かれているが、
これは**並列実装中の都合**であり、マージ後の今は成立しない理由。
`THROTTLER_CONFIG` に `share-invite`（30/分）/ `share-redeem`（30/分）を足して 1 方式へ揃えるべき。
（挙動そのものは契約どおりなので機能上の欠陥ではない）

### 5. 受信箱の tour 名解決が論理削除を見ていない

✅ **2026-08-14 修正済み**: `resolveTourNames` に `deletedAt: null` を追加し、`ListInboxUseCase` で
tour スコープかつ名前解決できなかった行（＝削除済みツアー）を一覧から除外するようにした。
契約は `api-contract-delta.md` §4.1 に追記済み。

`share-recipient-access.service.ts:72-80` の `resolveTourNames` は `deletedAt` を見ないため、
オーナーがツアーを削除しても受信箱には名前付きで並ぶ。開くと `ResolveShareUseCase` →
`TourMatrixService`（削除済みを除外）→ `SHARE_INVALID` 404 になり、
「一覧にあるのに開けない」状態になる。一覧側で除外するか、開けない旨を出す方が親切。

### 6. 他人の閲覧で全招待者が未読に戻る

`recordView`（`view_count` 加算）が `share_links.updated_at` を進めるため、
招待者 A が開くと招待者 B の `unread` が true に戻る。契約 §4.1 の定義どおりの実装ではあるが、
「オーナーが更新した」の代理指標として `updated_at` を使っていることの副作用。
将来 `last_edited_at` / 内容変更ベースへ寄せるのが妥当（本差分では契約変更になるため見送り）。

---

## 軽微 / 提案

7. ✅ **2026-08-14 修正済み**: `TokenThrottlerGuard` / `tokenTracker`（`common/throttling/token-throttler.guard.ts`）は
   `/public/*` 廃止で**利用者ゼロのデッドコード**だったため、spec ごと削除した。
8. `ShareRecipientAccessService` 冒頭コメント（`share-recipient-access.service.ts:8-9`）の
   「`shares.service.ts`（T3 所有）を編集できない都合上」は並列開発の都合の記述。
   マージ後の読者に誤った制約を伝えるので整理したい（4 と同種）。
9. `RemoveRecipientUseCase` は `:account_id` の形式検証をしない（`deleteMany` なので実害なし・冪等契約どおり）。
10. `GET /v1/shares/received/:id` はオーナー閲覧でも `view_count` を加算する。
    契約は「既存どおり」としか書いていないので違反ではないが、統計としてはノイズ。

---

## 良かった点

- **403 / 404 の出し分けが契約どおり**。`SHARE_NOT_INVITED` は
  `redeem-share.use-case.ts:43` の 1 箇所だけ（`grep -rn SHARE_NOT_INVITED apps/api/src` で確認）。
  `:id` 経路は非招待も未知も同一の `SHARE_INVALID` + **同一メッセージ**で、存在を confirm しない。
- **PATCH の判定順序**（`shares/received/use-cases/update-item.use-case.ts:41-51`）が契約どおり
  「①有効性 → ②招待判定 → ③permission」。permission 判定は `shares/board/` 側に分離されており、
  順序を逆にしにくい構造になっている。
- **受信箱レスポンスに機微情報なし**。`received-share.presenter.ts` は行を spread せず契約キーだけを
  明示的に組み立てており、`token` / `token_hash` / `scope_id` / 内部 UUID / 他の招待者 / 会員番号が入らない。
- **マスキングの移設が「移設のみ」**。`public-share.presenter.ts` 系はロジック無改変で
  `shares/board/` へ移動し、既存 spec もそのまま通っている（組み立て箇所は 1 本のまま）。
- **削除の取りこぼしゼロ**。`shared_with_account_ids` / `PublicApiClient` / `OpenSharedBoardView` /
  `SharedBoardTokenStore` の**実シンボル残存は 0**（ヒットはコメント・リクエストキー名・テスト名のみ）。
  `AdGatekeeperTests` / `AdSlotForbiddenScreensTests` / `HomeView` の 3 点セットも同時に処理済み。
- **「受け取り側は未ログイン前提」という旧前提のコメントが全て書き換えられている**
  （`ApiClient.swift:11` / `Repositories.swift` / `RemoteSharedBoardRepository.swift:7` /
  `SharedBoardView.swift` / `AccountLocalDataClearing.swift` / `SharedBoardStore.swift`）。IOS-2 の温床を潰せている。
- `GLOBAL_PREFIX_EXCLUDE` は `['health','readyz']` のみで巻き添え削除なし。
  `/public/shares/:token` と `/v1/public/shares/:token` が 404 であることを `app.setup.spec.ts` で固定している。
- 招待 UI（ツアー共有 / 名義サマリー共有）は同一パターンで実装され、
  **実在確認をクライアントでしない**（形式・件数のみ）方針が守られている（IOS-4）。

---

## 検証（修正後）

| コマンド | 結果 |
|---|---|
| `cd apps/api && npx tsc --noEmit` | クリーン |
| `cd apps/api && npm test` | 87 suites / **884 tests passed** |
| `cd apps/api && npm run build` | 成功 |
| `cd meigicho/Packages/Domain && swift test` | 207 tests passed |
| `cd meigicho/Packages/Network && swift test` | 165 tests passed |
| `xcodebuild -scheme Meigicho … build` | **BUILD SUCCEEDED** |

**重大ゼロを確認**（上記 1 を修正し再レビュー済み）。中 4〜6・軽微 7〜10 は本差分のマージを止めない。

## 手動確認手順（実 DB / 実機が要る範囲）

1. A で共有作成（B を招待）→ B でログイン → ホームの受信箱に 1 件・未読ドットあり
2. B が行をタップ → ボード表示 → 戻って pull-to-refresh で**未読ドットが消える**（重大 1 の回帰確認）
3. C（非招待）が `meigicho://share/<token>` を開く → 「この共有はあなたに共有されていません」
4. C が `GET /v1/shares/received/<share_id>` を直接叩く → 404 `SHARE_INVALID`
5. アプリ未起動状態でリンクをタップ（ログイン済み端末）→ **サインインシートが出ずに**ボードが開く（中 3 の確認）
