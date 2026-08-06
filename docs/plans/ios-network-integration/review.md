# review — ios-network-integration（T0〜T4b）

レビュー日: 2026-08-05 / レビュアー: code-reviewer（実装者とは別セッション）
対象: `meigicho/` 配下の全変更（T0・T1・T1b・T1c・T2・T3・T4・T4b）+ `meigicho/project.yml`
契約の正: `docs/plans/backend-domain-modules/api-contract.md` / `docs/plans/backend-auth-and-shares-extension/api-contract-delta.md` / `docs/plans/ios-network-integration/contract-mapping.md`

## 検証ゲート（レビュアー自身で実行）

| コマンド | 結果 |
|---|---|
| `xcodebuild -project meigicho/Meigicho.xcodeproj -scheme Meigicho -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/meigicho-build-review CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED** |
| `cd meigicho/Packages/Core && swift test` | 17 tests / 0 failures |
| `cd meigicho/Packages/Domain && swift test` | 133 tests / 0 failures |
| `cd meigicho/Packages/Network && swift test` | 122 tests / 0 failures |

合計 272 テスト全緑。実装者の申告と一致。

---

## レビュー結果サマリ

- 重大: **1 件**
- 中: **5 件**
- 軽微/提案: **6 件**

---

## 重大 (Must Fix)

### 重大-1 `identity_summary` 共有ボードを iOS が開けない（デコード失敗）

- `meigicho/Packages/Network/Sources/Network/DTO/SharedBoardDTO.swift:11-27`（`SharedBoardResponse`）
- `meigicho/Packages/Network/Sources/Network/DTO/SharedBoardDTO.swift:44-74`（`SharedBoardItemResponse`）
- 発行側の導線: `meigicho/Packages/Features/Sources/Features/Share/SharePreviewView.swift:137`

`GET /public/shares/:token` は `scope_type` によって **items の形が完全に別物**になる。

```
// tour                               // identity_summary
{ event_name, venue, event_date,      { name, visible,
  round_name, rep_name, rep_color,      application_count, won_count }
  companions, status, seat, ... }     ※ visible:false のときは件数キーごと無い
                                      ※ tour キーも存在しない
```

根拠（一次ソース）:
- `docs/plans/backend-domain-modules/api-contract.md:627-637`（identity_summary の JSON 例）
- `apps/api/src/public/public-share.presenter.ts` の `IdentitySummaryPayload` / `toIdentitySummaryItem`
- `apps/api/src/public/use-cases/resolve-share.use-case.ts:68-70`（`scopeType === 'identity_summary'` で別 payload を返す）

iOS の `SharedBoardItemResponse` は `event_name` / `rep_name` / `companions` / `status` を **非 Optional** で宣言しているため、
identity_summary のペイロードは必ずデコードに失敗し、`AppError.decoding` → 画面には「応答を解釈できませんでした」しか出ない。

これは机上の話ではなく **アプリ自身が作れるリンク**で起きる:
`SharePreviewView`（名義タブ → 共有）の「共有リンクを作成」→ `ShareLinkStore.createIdentitySummaryLink()` →
受け取り側が `OpenSharedBoardView` / `meigicho://share/<token>` で開く、という縦串が全て実装済みで、
最後の 1 段だけが壊れている。`SharedBoardView` も `board.scopeType` を一切参照せず、tour 用の 5 列表しか描かない。

テストにも identity_summary の共有ボードケースが無い（`SharedBoardDTOTests.swift` / `RemoteSharedBoardRepositoryTests.swift` に該当なし）ので気づけていない。

**修正案**（どれか 1 つを選ぶ。契約の変更は不要）:
1. `SharedBoardResponse` を `scope_type` でディスパッチする enum にし、`SharedBoard` を
   `case tour([SharedBoardItem])` / `case identitySummary([SharedIdentitySummaryItem])` の 2 系統にして
   `SharedBoardView` に identity_summary 用の 2 列表（名義名 / 申込・当選件数、`visible:false` は「非公開」）を足す。
2. 当面 tour だけを扱うと決めるなら、`SharePreviewView` の identity_summary 発行導線を落とすか、
   `scope_type == "identity_summary"` を**明示的に**検出して「このリンクはブラウザで開いてください」等の
   専用メッセージにする（`.decoding` に落とさない）。

**注記**: `contract-mapping.md` §4.8 が tour の形しか書いていないため、実装者が仕様どおりに書いた結果でもある。
修正時は `contract-mapping.md` §4.8 にも identity_summary の形を追記して SSOT を揃えること。

---

## 中 (Should Fix)

### 中-1 read リンクの行 ID が衝突しうる（`ForEach` の id 重複）

`meigicho/Packages/Domain/Sources/Domain/Models/SharedBoardModels.swift:70-72`

```swift
public var id: String {
    handle?.itemKey ?? "\(eventName)|\(repName)|\(eventDate?.timeIntervalSince1970 ?? 0)"
}
```

`round_name` が入っていないため、**同じ公演・同じ代表名義で申込を複数持つ**（FC1次 / FC2次 など、本アプリの中核ユースケース）と
read リンクで id が重複する。`SharedBoardView.swift:117` は `ForEach(..., id: \.element.id)` を使っているので
行の描画が壊れる（SwiftUI の実行時警告 + 行の取り違え）。
また `history_visible = false` の名義は `rep_name` が全て `"非公開の名義"` にマスクされるため、
同一公演の非公開行同士でも衝突する。

修正案: フォールバックキーに `roundName` と配列インデックスを含める。
（write リンクは `item_key` が一意なので影響しない）

### 中-2 ログアウト中に完了した refresh が Keychain を書き戻す

`meigicho/Packages/Network/Sources/Network/ApiClient.swift:151-155`（`store`）/ `:174-178`（`clearSession`）

`clearSession()` / `endSession()` は `refreshTask` をキャンセルしない。
`.bearer` リクエストの 401 refresh が飛んでいる最中にユーザーがログアウトすると、
`clearSession()` で Keychain を消した**後**に `runRefresh` → `store(pair)` が走り、
新しい refresh token が Keychain に書き戻される。次回起動で `restoreSession()` が成功し、
**ログアウトしたはずのユーザーが黙って復帰する**。

修正案: `clearSession()` / `endSession()` で `refreshTask?.cancel(); refreshTask = nil` し、
`store(_:)` に「セッション世代（epoch）」を持たせて古い世代の書き込みを捨てる。

### 中-3 Keychain の書き込み失敗を握りつぶしている

`meigicho/Packages/Network/Sources/Network/TokenStore.swift:47-61`
`meigicho/Packages/Network/Sources/Network/SharedBoardTokenStore.swift:52-68`

`SecItemUpdate` が `errSecItemNotFound` 以外で失敗した場合と、`SecItemAdd` の `OSStatus` が
どちらも無視されている。refresh token が保存できていないと **次回起動でサイレントログアウト**になるが、
ログにも UI にも何も残らないため原因調査ができない。
`AppLogger` は本文を受け取れない設計なので、`logger.event("keychain_write_failed_\(status)")` のような
固定イベント名 + OSStatus（値は秘密ではない）だけでも残すべき。

### 中-4 共有ボードの再読み込み失敗で表全体が消える（E-1 と不一致）

`meigicho/Packages/Features/Sources/Features/SharedBoard/SharedBoardView.swift:63-72`

`SharedBoardStore.load()` は失敗時に `board` を保持する（`SharedBoardStore.swift:206-207` のコメントどおり）が、
View 側が `else if let error = store.state.error` を `else if let board = store.board` **より前**に置いているため、
「最新を取得」でオフラインだった瞬間に表が丸ごと消える。
他画面（`HomeView.swift:112-117` / `ApplicationListView.swift:88-92`）は
「エラーバー + 既存データ」を並べており、そちらと平仄が合っていない。

修正案: エラーバーを `board` 描画の前に**並べて**出す（`actionError` と同じ扱いにする）。

### 中-5 `SheetPresenter` だけ `@unchecked Sendable`（他ストアとの平仄崩れ）

`meigicho/Packages/Features/Sources/Features/Navigation/SheetPresenter.swift:3-4`

```swift
@Observable
public final class SheetPresenter: @unchecked Sendable {
    public var activeSheet: AppSheet?
```

`SWIFT_STRICT_CONCURRENCY: complete`（`project.yml`）の下で、可変プロパティを持つクラスに
`@unchecked Sendable` を付けて検査を黙らせている。他の Observable ストア
（`AuthStore` / `ProfileStore` / `IdentityStore` / `ApplicationStore` / `ShareLinkStore` / `SharedBoardStore` /
`AppSettingsStore.swift:8`）は全て `@MainActor @Observable` で揃っているので、ここだけ例外。
実際に触るのは MainActor のコードだけなので現時点で実害は無いが、潜在的なデータ競合を型で許してしまっている。

修正案: `@MainActor @Observable public final class SheetPresenter {}` にして `@unchecked Sendable` を外す。

---

## 軽微 (Nice to Have)

1. **`GOOGLE_REVERSED_CLIENT_ID` 未設定時に空の URL スキームが残る**
   `meigicho/project.yml`（`GOOGLE_REVERSED_CLIENT_ID: ""`）→ `meigicho/App/Info.plist` の
   `CFBundleURLSchemes` に空文字列 1 件が入る。実行時は無害だが App Store 検証で警告になりうる。
   Google 未設定の構成では URL type ごと出さないか、ダミーではない値を必須にするのが安全。

2. **`#Preview` 内の `SampleData` 参照が `#if DEBUG` で囲われていない**
   `meigicho/Packages/Features/Sources/Features/Navigation/MainTabView.swift:43-50` ほか。
   実行時経路からは呼ばれていない（IOS-1 の観点では問題なし）が、`Domain/Preview/SampleData.swift` の
   サンプル氏名がリリースバイナリに残る。

3. **`AppLogger.unknownValue` の `rawValue` が `privacy: .public`**
   `meigicho/Packages/Core/Sources/Core/AppLogger.swift`。enum の生値だけを想定した設計だが、
   `ProfileStore.saveThemeColor`（`ProfileStore.swift:109`）は**利用者が入力した値**を渡している。
   用途が「未知の enum 値」に限定されるようメソッドを分けるか、`.private` に落とす検討を。

4. **`Domain` が `Core` を import している**
   `contract-mapping.md` §5 は「`Domain` は `Foundation` のみ import する」と書いているが、実装は
   `import Core`（`AppLogger` / `UUIDv7` / `Nonce` / `DateFormatting`）。
   `Core` に `URLSession` / `Security` / `SwiftData` は無いので NFR-5 の趣旨には反していない。
   `contract-mapping.md` の文面を実装に合わせて直しておくとよい。

5. **`AccountIDValidator.isValid` が全角数字を通す**
   `meigicho/Packages/Domain/Sources/Domain/Models/ShareModels.swift:102-106`。
   `$0.isNumber` は `１`（U+FF11）等も true になるため、BE の `^ACC-[0-9A-F]{6}$` で 400 になる値を
   送信前チェックが通してしまう（往復が 1 回増えるだけ）。`$0.isASCII && $0.isNumber` に揃えると
   `EmailCredentialRule.isValidResetCode`（`AuthStore.swift:364`）と平仄も合う。

6. **`AppSheet.signIn` の `id` が `reason` を含まない**
   `meigicho/Packages/Features/Sources/Features/Navigation/AppRoute.swift`。
   シート表示中に別の理由で `presentSignIn(reason:)` を呼んでも見出しが更新されない。
   現状の導線では起こらないが、id に理由を含めるほうが安全。

---

## 良かった点

- **未認証経路の隔離が型レベルで効いている（最重要）**
  `Endpoint.Path` を `.versioned` / `.publicPath` の 2 ケースにし、`ApiClient.perform`（`ApiClient.swift:61-64`）と
  `PublicApiClient.perform`（`PublicApiClient.swift:53-55`）が**双方向に**取り違えを弾いている。
  `PublicApiClient` は `TokenStore` / `ApiClient` を参照せず、`extraHeaders: [:]` で送るため
  `Authorization` が混入する経路自体が無い。`AppEnvironment.swift:49-53` の配線も
  `RemoteSharedBoardRepository(client: publicApiClient)` のみ。
  **共有ボードを開いて 401 を受けても自分のアカウントがログアウトする経路は存在しない**（R7 / AC-SB-13-M）を確認。

- **パスワード変更・リセット後のトークン採用（A5 / A6）が正しい**
  `AuthStore.changePassword`（`AuthStore.swift:225-226`）が `session.adoptSession(tokens)`、
  `resetPassword` は `performEmailSignIn` → `adopt` 経由。どちらも戻り値を捨てていない。
  `RemoteAuthRepository.changePassword` だけが `.bearer`、他 4 本は `.none` という切り分けも契約どおり。

- **Apple `identity_token` / Google `id_token` のキー取り違えが無い**
  `AuthDTO.swift:63-85`。`CodingKeys` にリテラルで書かれており、テスト（`AuthDTOTests`）も存在。

- **`editable ?? true` を型で不可能にしている**
  `SharedItemHandle.init?(itemKey:rev:editable:)`（`SharedBoardModels.swift:89-94`）が 3 つ揃わないと nil を返し、
  `SharedBoardStore.isEditable`（`SharedBoardStore.swift:141-143`）が `canEdit && handle?.editable == true`。
  `SharedBoardView` は編集不可の行にタップ要素を置かない（`statusCell` / `seatCell` の else 分岐）。

- **未知値の黙殺が無い**
  `AppError.from(envelope:)` は未知 code を `.unknown(code:message:)` のまま返す。
  `permission` / `scope_type` は enum デコードで失敗させ、`read` / `tour` に落とさない。
  `status` / `relation` / `plan` のフォールバックは `DecodedEnum.didFallback` で必ずログに残る。

- **`CONFLICT` の格上げが `RemoteSharedBoardRepository` に閉じている**
  汎用マッパーは常に `.conflict`、`details.current` を読むのは `promoteShareItemConflict` だけ
  （`RemoteSharedBoardRepository.swift:62-90`）。`seat` の型不一致では格上げしない実装も契約どおり。
  T4b で追加された `PublicApiClient.send(_:as:promoteError:)` は純追加で、既存の `send` / `sendVoid` は
  `promoteError: nil` を渡すのみ。認証なし・リトライなしという性質は変わっていない（申し送り事項を検証済み）。

- **プラン上限を iOS で先回りしていない（IOS-4）**
  名義上限・write 共有の公演数上限（3）をハードコードした箇所は無し（grep 済み）。
  403 の `details.limit/current` を文言化するだけで、押させない細工が無い。
  パスワードも 8〜128 文字の長さチェックのみで、独自の文字種要件を足していない
  （`EmailCredentialRule.isValidPassword`）。ログイン側は下限すら掛けない判断も正しい。

- **パッケージ依存の逆流が Package.swift で塞がれている（IOS-5）**
  `Features/Package.swift` の依存は `Core` / `DesignSystem` / `Domain` のみで `Network` を含まない。
  `Domain` の import は `Foundation` と `Core` だけ（`URLSession` / `Security` / `SwiftData` なし）。

- **死にコードの掃除ができている（IOS-1）**
  `TourShareStore` の UserDefaults 永続化は削除済みで、参照は「廃止した」旨のコメントのみ。
  `SampleData` の実行時参照は無く、`AppEnvironment` の `InMemory*` は
  `-UITestUseInMemoryStores`（DEBUG 限定）でしか選ばれない。

- **ゲストモード（T1c）で BE を叩かない**
  `refreshable` / `.task` の全ての `load()` 呼び出しに `auth.isGuest` ガードがあり
  （`HomeView.swift:31` / `ApplicationListView.swift:30,60,64` / `AccountView.swift:41`）、
  一覧描画も `if auth.isGuest { SignInPromptCard }` で分岐。
  書き込み入口は `SheetPresenter.present(_:requiringSignIn:reason:)`（`GuestGate.swift:38-40`）に集約され、
  「フォームを開かせてから保存で失敗させる」経路が無い。

- **秘密情報のログ漏洩が無い**
  リポジトリ全体で `print` / `NSLog` / `os_log` 直呼びゼロ。`AppLogger` は `code` / `requestID` /
  固定イベント名しか受け取れない引数設計。Google のトークン交換失敗時も本文を記録していない
  （`GoogleSignInService.swift:100-104`）。共有 token は `KeychainSharedBoardTokenStore` で
  SHA-256 を account キーにし、本体は value data 側（`SharedBoardTokenStore.swift:31-35`）。
  service 名前空間も `jp.meigicho.app.auth` / `jp.meigicho.app.sharedboard` で分離済み。

- **並行 refresh の直列化**
  `ApiClient.currentAccessToken(replacing:)` が `refreshTask` に集約し、
  「別の refresh が既に成功していれば refresh しない」判定（`current != previous`）まで入っている（E-5）。
  `ApiClientRefreshTests` で担保されている。

- **API 契約 3 層の一致（重大-1 を除く）**
  Prisma / presenter / DTO を突き合わせた結果、`applications` / `identities` / `memberships` /
  `tours` / `events` / `me` / `shares` は**フィールドの取りこぼしなし**。
  特に `edit_count` / `last_edited_at` / `permission`（`ShareDTO.swift:34-36,27`）は追加分まで拾えている。
  `token` / `url` を `ShareResponse` に定義しない（C4）、`member_no` / `member_no_cipher` を型として持たない（§4.4）、
  `account_id` / `plan` / `id` を `UpdateMeRequest` に持たない（C6）といった
  「型として存在させない」防御も契約どおり実装されている。

- **`Patchable<T>` による「送らない」と「null を送る」の区別**が全 PATCH DTO で一貫している。
  `note` の空文字 → `nil` 変換も送受信で対称（`IdentityDTO.swift:154-159` / `MembershipDTO.swift:152-157`）。

---

## 再レビュー結果（修正差分）

再レビュー日: 2026-08-05 / レビュアー: code-reviewer（実装者・初回レビュアーとは別セッション）
対象: 前回指摘（重大-1 / 中-1〜5）の修正差分のみ。T0〜T4b 全体の再走査はしていない
確認した実体: `SharedBoardDTO.swift` / `SharedBoardModels.swift` / `SharedBoardStore.swift` / `SharedBoardView.swift` /
`ApiClient.swift` / `KeychainWrite.swift` / `TokenStore.swift` / `SharedBoardTokenStore.swift` / `SheetPresenter.swift` /
`contract-mapping.md` §3.5・§4.8 と対応テスト。BE 側は `public-share.presenter.ts` / `resolve-share.use-case.ts` を一次ソースとして突き合わせ

### 検証ゲート（レビュアー自身で実行）

| コマンド | 結果 |
|---|---|
| `xcodebuild ... -derivedDataPath /tmp/meigicho-build-review2 CODE_SIGNING_ALLOWED=NO build` | **BUILD SUCCEEDED** |
| `cd meigicho/Packages/Core && swift test` | 17 tests / 0 failures |
| `cd meigicho/Packages/Domain && swift test` | 138 tests / 0 failures（前回 133 → +5） |
| `cd meigicho/Packages/Network && swift test` | 139 tests / 0 failures（前回 122 → +17） |

合計 294 テスト全緑。

### サマリ

- 重大: **0 件**（重大-1 は解消）
- 中: **0 件**（中-1〜5 すべて解消）
- 軽微/提案: **5 件**

---

## 前回指摘の解消確認

### 重大-1 `identity_summary` のデコード失敗 → **解消**

- `SharedBoardResponse.init(from:)`（`SharedBoardDTO.swift:36-56`）が **`scope_type` を先に読んでから** items のデコード経路を分けている。
  tour の非 Optional キーが identity_summary に適用される経路が型として消えた
- BE の `IdentitySummaryPayload` / `IdentitySummaryVisibleItem` / `IdentitySummaryHiddenItem`（`public-share.presenter.ts:59-80`）と
  `SharedIdentitySummaryItemResponse`（`SharedBoardDTO.swift:63-75`）を 1 キーずつ突き合わせ：
  `name: String`（必須）/ `visible: Bool`（必須）/ `application_count` `won_count` は **Optional** — 一致。
  `toIdentitySummaryItem`（同 158-169）が `visible:false` で件数キーを**出さない**契約と、iOS の Optional 受けが対応している
- `permission` は BE が常に `'read'` を出す（同 152）。iOS は `decodeIfPresent ?? .read`（`SharedBoardDTO.swift:51`）で、
  キーが欠けても **write に倒れない**。逆に tour では `decode`（必須）にしてあり、欠けたら失敗させる（`:44`）。この非対称は妥当
- **tour スコープの回帰なし**：read / write の既存 3 テスト（`testReadPayloadDecodesWithoutHandleKeys` /
  `testWritePayloadDecodesHandlePerItem` / `testUnknownStatusFallsBackToApplied`）が全緑。
  `tour` キーは `decodeIfPresent`、`items` は必須で従来どおり
- 契約違反の扱いが**マスキング側に倒れている**のを確認（`SharedBoardDTO.swift:191-196`）。
  `visible:true` なのに件数なし → 0 と偽らず非公開扱い。`visible:false` なのに件数あり → 件数を捨てる。両方ログに残す
- 画面側も配線済み（IOS-1 / IOS-3）：`SharedBoardView.boardContent(_:)`（`SharedBoardView.swift:98-115`）が
  `board.content` で分岐し、identity_summary は 3 列表 + 「非公開」セル（`:137-177`）。
  `permissionHint`（`:118-131`）も identity_summary 専用文言。`SharedBoardStore.canEdit`（`SharedBoardStore.swift:139-142`）が
  `case .tour` を要求するので、`permission:"write"` を騙られても編集 UI が出ない（テスト
  `testIdentitySummaryBoardCannotEditEvenWithWritePermission` で `updateCallCount == 0` を確認）
- `contract-mapping.md` §3.5（`SharedBoardContent` / `SharedIdentitySummaryItem` / `SharedIdentityCounts`）と
  §4.8（identity_summary の JSON 形 + P7 / P8 / P9）に追記済み。SSOT のズレも解消

### 中-1 read リンクの行 ID 衝突 → **解消**

`SharedBoardItem.id`（`SharedBoardModels.swift:203-206`）が `"#\(rowIndex)|\(eventName)|\(roundName ?? "")|\(repName)"`。
`rowIndex` は `items.enumerated()` の offset（`SharedBoardDTO.swift:173`）なので、**内容が完全同一でも必ず一意**。
再現条件（同一公演・同一名義・ラウンド違い、かつ非公開名義で `rep_name` が全て `"非公開の名義"`）を
そのまま JSON にしたテスト `testReadLinkRowIDsAreUniqueAcrossRounds`（`SharedBoardDTOTests.swift:230-249`）で 3 件が別 id になることを確認。
`SharedIdentitySummaryItem.id` も同様に `rowIndex` 込み（同名 2 件のテストあり）。
write リンク（id = `item_key`）は従来どおりで、`replace(itemID:with:)`（`SharedBoardStore.swift:303-310`）が
PATCH レスポンスに無い `rowIndex` を元の行から引き継ぐので、行 id が保存中に変わることもない。

### 中-2 ログアウト中の refresh が Keychain を書き戻す → **解消**

`sessionEpoch`（`ApiClient.swift:33`）を導入し、`clearSession()`（`:197-203`）/ `adoptSession(_:)`（`:191-195`）/
`endSession()`（`:177-183`）が `beginNewSessionEpoch()`（`:134-138`）で世代を進めつつ `refreshTask` を cancel している。
`runRefresh` は **store の直前** に `guard epoch == sessionEpoch`（`:153-157`）を置き、
このガードと `accessToken` 代入の間に suspension point が無いので、判定と採用が原子的。
「新しいセッションを誤って壊す経路」も塞がれている：

- 失敗時の `endSession()` に `epoch == sessionEpoch` 条件が付いている（`:164`）ので、
  **古い世代の refresh 失敗が新しいセッションを消さない**
- `currentAccessToken` の `refreshTask = nil` も世代一致時のみ（`:125` / `:128`）で、後発の refresh task を消さない

テスト 3 本（`testRefreshCompletingAfterSignOutDoesNotRestoreToken` / `testRequestAfterSignOutDoesNotReviveSession` /
`testStaleRefreshDoesNotOverwriteNewerSession`、`ApiClientRefreshTests.swift:179-254`）は
0.2 秒の遅延レスポンスで実際に in-flight を作ってから `clearSession()` / `adoptSession()` を挟んでおり、見せかけではない。

### 中-3 Keychain 書き込み失敗の握りつぶし → **解消**

`KeychainWrite.failureEvent(operation:status:)`（`KeychainWrite.swift:24-28`）に判定を集約し、
`KeychainTokenStore.write/clear`（`TokenStore.swift:63,65,70`）と
`KeychainSharedBoardTokenStore.save/remove`（`SharedBoardTokenStore.swift:72,74,81`）が呼んでいる。

**NFR-4 準拠を確認**：生成される文字列は `keychain_<update|add|delete>_failed_<OSStatus>` のみ。
token 値・service 名・account（token の SHA-256）・URL を一切含まない。
出力先は `AppLogger.event(_:)`（`AppLogger.swift:27-29`）で、`privacy: .public` だが内容は固定名 + OSStatus なので問題なし。
`testFailureEventCarriesOperationAndStatusOnly`（`KeychainWriteTests.swift:32-40`）が
`"token"` / `"jp.meigicho"` を含まないことまで検査している。
`SecItemUpdate` / `SecItemDelete` の `errSecItemNotFound` を正常扱いにする例外も正しい（それぞれ「この後 add する」「clear は冪等」）。

### 中-4 再取得失敗で表全体が消える → **解消**

`SharedBoardView.content`（`SharedBoardView.swift:60-94`）で `store.state.error` の `ErrorBar` を
`if let board = store.board` の**前に並べて**出す形になり、`else if` の分岐ではなくなった。
`ProgressView` も `store.board == nil` のときだけ（`:75`）。
`HomeView` / `ApplicationListView` の「エラーバー + 既存データ」と平仄が揃った。
`SharedBoardStore.load` 側の「読み込み済みの内容は消さない」（`SharedBoardStore.swift:210-211`）は従来どおりで、
`testTransportFailureOnReloadKeepsBoard`（`SharedBoardStoreTests.swift:229-240`）が
`state.error == .offline` かつ `board != nil` を検証。

### 中-5 `SheetPresenter` の `@unchecked Sendable` → **解消**

`@MainActor @Observable public final class SheetPresenter`（`SheetPresenter.swift:5-11`）。`@unchecked Sendable` は削除済み。
他の Observable ストア（`AuthStore` / `ProfileStore` / `IdentityStore` / `ApplicationStore` / `ShareLinkStore` /
`SharedBoardStore` / `AppSettingsStore`）と完全に同形になった。`SWIFT_STRICT_CONCURRENCY: complete` のままビルド成功。

### 既存モジュールへの回帰

- Domain +5 / Network +17 テストはすべて純増で、既存 272 本に赤なし
- `SharedBoard.items` を computed property 化（`SharedBoardModels.swift:88-98`）した際、
  setter に `guard case .tour` を置いて「identity_summary のボードに tour 行を生やす」経路を塞いである。
  `SharedBoardStore.apply` の楽観更新・`replace` / `redraw` は `board?.items[index]` 経由で従来どおり動作（テスト全緑）
- `ShareScope`（`AppEnums.swift:86-89`）の生値は `tour` / `identity_summary` で BE と一致。未知値はデコード失敗（`testUnknownScopeTypeFailsDecoding`）
- `SharedBoardStore` は依然 `ApiClient` / `TokenStore` に触れておらず、AC-SB-13-M（共有ボードで自分のセッションが落ちない）は維持

---

## 軽微 (Nice to Have) — 再レビューで新規

1. **中-2 の残余：Keychain 書き込みと削除の順序は保証されない**
   `ApiClient.store(_:)`（`ApiClient.swift:171-175`）の `await tokenStore.write(...)` は
   nonisolated async なので、そこで actor を解放する。その隙間に `clearSession()` が走ると
   `tokenStore.clear()` と `write()` が並行に走り、**clear が先に完了すると refresh token が残る**。
   世代ガードにより窓は「ネットワーク往復ぶん」から「同期的な `SecItemUpdate` ぶん」へ大幅に縮んでおり実害はほぼ無いが、
   完全には閉じていない。`store(_:)` に epoch を渡し、書き込み後にもう一度 `epoch == sessionEpoch` を見て
   ズレていたら `tokenStore.clear()` するか、`RefreshTokenStoring` の実装を actor にして直列化すると閉じる。

2. **中-3 の対称：読み取り側の OSStatus は依然として無記録**
   `KeychainTokenStore.read()`（`TokenStore.swift:39-48`）と
   `KeychainSharedBoardTokenStore.list()`（`SharedBoardTokenStore.swift:40-53`）は
   `errSecSuccess` 以外を一律 `nil` / `[]` に落としている。
   `read()` が `errSecInteractionNotAllowed` などで nil を返すと `restoreSession()` が `.signedOut` になり、
   **token は無事なのにサインアウト**という、中-3 が問題にしたのと同じ「ログの無いサイレントログアウト」になる。
   `kSecAttrAccessibleAfterFirstUnlock` のおかげで発生条件は狭いが、
   `errSecItemNotFound` 以外を `KeychainWrite.log` と同じ形で記録しておくと診断性が揃う。

3. **`ErrorBar` が 2 本並びうる**
   `SharedBoardView.swift:68-88`。`state.error`（取得失敗）と `actionError`（429 / 404）が同時に立つと
   同じ形のバーが縦に 2 本出る。導線上は起きにくいが、`actionError` を優先して 1 本にするか見た目を変えると親切。

4. **`identitySummaryTable` だけ横スクロールが無い**
   `SharedBoardView.swift:137-169`。tour の `table(_:)`（`:181-219`）は `ScrollView(.horizontal)` で包んでいるが、
   identity_summary 側は包んでいない。3 列 × `minWidth: 100` なので実害はまずないが、
   長い名義名で右端が詰まる可能性がある。

5. **前回の軽微 1〜6 は未対応のまま**
   確認した範囲では `project.yml:34`（空の `GOOGLE_REVERSED_CLIENT_ID`）、
   `ShareModels.swift:102-106`（`AccountIDValidator.isValid` が全角数字を通す）、
   `AppRoute.swift:22-28`（`AppSheet.signIn` の id に `reason` を含まない）はいずれもそのまま。
   今回の修正スコープ外なので指摘の再掲のみ。

---

## 良かった点（再レビュー分）

- **重大-1 の直し方が「弾く」ではなく「型で分ける」になっている**
  `SharedBoardContent`（enum）を Domain に置き、`scopeType` を content から導出する設計（`SharedBoardModels.swift:9-39`）で、
  「identity_summary なのに tour の行を持つ」状態がそもそも作れない。`items` の setter ガードまで入れて
  後から壊す経路も塞いである。修正案 2（発行導線を落とす）ではなく修正案 1 を選び、
  `SharePreviewView` の発行導線を殺さずに縦串を通し切ったのは IOS-1 / IOS-3 の観点で正しい。

- **契約違反時の倒し方が一貫して「安全側」**
  `visible` と件数の食い違い → 非公開に倒す。`permission` 欠落 → identity_summary は read に倒す（tour は失敗させる）。
  未知の `scope_type` → どちらにも落とさず失敗。すべてログに残る。BE-2 の iOS 版として筋が通っている。

- **テストが再現条件をそのまま写している**
  `testReadLinkRowIDsAreUniqueAcrossRounds` は「同一公演・同一日・非公開名義・FC1 次/FC2 次」という
  前回レビューが書いた再現条件そのままの JSON。`ApiClientRefreshTests` の 3 本も遅延レスポンスで実際に
  in-flight を作っており、ロジックを迂回した見せかけのテストではない。

- **SSOT の追従漏れが無い**
  `contract-mapping.md` §3.5（Domain 型）と §4.8（JSON 形 + P7 / P8 / P9）の両方を更新しており、
  「実装だけ直してドキュメントが tour のままで、次の実装者が同じ罠を踏む」形になっていない。
