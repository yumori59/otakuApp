# contract-mapping — ios-network-integration

**API 契約の正は次の 2 本（両方読むこと）。本書はそれを変更しない。**

1. `docs/plans/backend-domain-modules/api-contract.md` — 基底契約
2. `docs/plans/backend-auth-and-shares-extension/api-contract-delta.md` — 認証拡張（Google / メール+パスワード / パスワードリセット）と共有 write 権限の差分。**基底契約と食い違う箇所はこちらが優先**

本書が確定するのは **iOS 側の DTO 定義と Domain 型へのマッピング**であり、実装エージェントはここを勝手に変えない。
変更が必要なら実装を止めて planner に差し戻す（rule 02）。

> **改訂 (BE 拡張反映)**: `questions-requirements.md` の Q3（Google / メールログイン UI の撤去）と Q7（共有ボード編集の撤去）は
> **ユーザー判断で覆り、どちらも「撤去しない」に確定**した。BE 側に対応実装が入っている。
> 影響セクション: §2.3 / §4.1 / §4.2 / §4.7 / §4.8 / §5 / §6。

---

## 1. 共通規約（iOS 側）

| 項目 | 決定 |
|---|---|
| baseURL | `Info.plist` の `API_BASE_URL`（Debug: `http://localhost:8080` / Release: Cloud Run URL）。末尾スラッシュ無し |
| パス組み立て | `baseURL + "/v1" + path`。ただし `GET /public/shares/:token` は `/v1` を付けない（`app.setup.ts:7-11` の exclude） |
| 共通ヘッダ | `Content-Type: application/json`（body があるときのみ） / `Accept: application/json` / `X-Request-Id: <UUIDv7 大文字なしの標準表記>` / `Authorization: Bearer <access>`（`@Public()` 以外） |
| デコード | `JSONDecoder()`（**`keyDecodingStrategy` を設定しない**）。DTO ごとに `CodingKeys` を明示 |
| エンコード | `JSONEncoder()`（`keyEncodingStrategy` を設定しない）。`CodingKeys` で snake_case を明示 |
| 日付 | DTO は全部 `String`。マッパーで変換（§2） |
| 空 body | 204 は `Void`。`ApiClient.send(_:)` と `ApiClient.sendVoid(_:)` を分ける |
| タイムアウト | `timeoutIntervalForRequest = 15`、`timeoutIntervalForResource = 60` |
| リトライ | **しない**（401 の refresh 再送 1 回のみ）。5xx / タイムアウトはユーザーの明示操作で再試行（`docs/05` §5「4xx はリトライしない」の延長。オフラインキューが無い今回は 5xx も自動リトライしない） |

### 1.1 `keyDecodingStrategy` を使わない理由

`.convertFromSnakeCase` は全キーを機械変換するため、BE が `member_no_last4` → `member_no_suffix` に改名しても
iOS 側は `memberNoLast4` のまま**ビルドが通り、値だけ nil になる**（IOS-2 の典型）。
`CodingKeys` に文字列リテラルで書いておけば、BE の改名時に `grep member_no_last4` で iOS 側が必ずヒットする。
BE 側も同じ理由で機械変換インターセプタを却下している（`backend-domain-modules/questions-requirements.md` Q10）。平仄を合わせる。

### 1.2 送信時の「送らない」と「null を送る」の区別

BE の PATCH は「送られたキーのみ更新」（`api-contract.md` §2・§3）。
Swift の `Encodable` は `Optional` を素直に書くと `nil` を **キーごと省略**する（`encodeIfPresent`）ので、これが既定の挙動でよい。
**明示的に null を送りたい場合**（`rep_membership_id` のクリアなど）は `enum Patchable<T> { case unchanged, set(T?) }` を使い、
`unchanged` は `encodeIfPresent` で省略、`set(nil)` は `encodeNil` する。
本計画で `Patchable` が必要なのは `rep_membership_id` / `renewal_on` / `fee_yen` / `joined_on` / `result_on` / `applied_on` / `note` の 7 フィールド。

---

## 2. 日付・ID・エラーの変換規則

### 2.1 日付（`Core/APIDateFormat.swift` に純関数で置く）

| 種別 | 例 | iOS 型 | 変換 |
|---|---|---|---|
| date-only（`@db.Date`） | `"2026-08-20"` | `Date` | **JST 00:00** の `Date` にする。`Calendar(identifier:.gregorian)` + `TimeZone(identifier:"Asia/Tokyo")` で `DateComponents(year:month:day:)` から生成 |
| date-only（送信） | `Date` → `"2026-08-20"` | — | 同じ JST カレンダーで `y/M/d` を取り出し `String(format:"%04d-%02d-%02d")` |
| datetime | `"2026-07-31T12:05:00.000Z"` | `Date` | `ISO8601DateFormatter` に `.withInternetDateTime, .withFractionalSeconds`。**フラクショナル無しも来うるので、失敗したら `.withInternetDateTime` のみで再試行する** |
| datetime（送信） | `Date` → ISO8601 UTC ミリ秒 | — | `onboarded_at` / `expires_at` のみ |

対象フィールド:

- date-only: `joined_on` / `renewal_on` / `event_date` / `applied_on` / `result_on`
- datetime: `created_at` / `updated_at` / `deleted_at` / `starts_at` / `onboarded_at` / `expires_at` / `revoked_at` / `last_viewed_at` / `generated_at`

**`starts_at` は datetime だが date-only の `event_date` と別物。混同しないこと**（BE は両方持つ）。

### 2.2 UUID

- `Core/UUIDv7.generate()` を新設（実装は `docs/05-ios-client.md` §2.4 のコードをそのまま採用）
- POST で `id` を送るのは: `identities` / `memberships` / `applications`（+ `tour.id` / `event.id` / `companions[].id`）
- `shares` の `id` は**サーバー生成**（`api-contract.md` §8）。送らない
- デコードは `UUID(uuidString:)`。失敗したらデコードエラー（黙って `UUID()` を作らない）

### 2.3 エラー envelope → `AppError`（`Domain/AppError.swift`）

```
{ "code": "...", "message": "...", "details": {...}, "request_id": "..." }
```

| `code` | HTTP | `AppError` | UI 文言（既定） |
|---|---|---|---|
| `VALIDATION_ERROR` | 400 | `.validation(message:)` | サーバーの `message` をそのまま出さず「入力内容を確認してください」+ 開発ビルドのみ `message` |
| `UNAUTHENTICATED` | 401 | `.unauthenticated` | （UI に出さない。refresh → 失敗ならログイン画面へ） |
| `AUTH_APPLE_INVALID` | 401 | `.appleSignInFailed` | 「Apple ID での確認に失敗しました。もう一度お試しください」 |
| **`AUTH_GOOGLE_INVALID`** | 401 | **`.googleSignInFailed`** | 「Google アカウントでの確認に失敗しました。もう一度お試しください」 |
| **`AUTH_CREDENTIALS_INVALID`** | 401 | **`.credentialsInvalid`** | ログイン時「メールアドレスまたはパスワードが違います」／パスワード変更時「現在のパスワードが違います」。**呼び出し側の文脈で文言を出し分ける**（サーバーの `message` は固定文字列なので使わない） |
| **`AUTH_RESET_CODE_INVALID`** | 401 | **`.resetCodeInvalid`** | 「コードが正しくないか、有効期限が切れています」 |
| `AUTH_REFRESH_INVALID` | 401 | `.sessionExpired` | （UI に出さない。ログイン画面へ） |
| `FORBIDDEN` | 403 | `.forbidden` | 文脈依存。共有ボードの行編集で受けたら「この行は編集できません」（**理由をサーバーが区別しないので推測して説明しない**）。パスワード変更で受けたら「このアカウントにはパスワードが設定されていません」 |
| `PLAN_LIMIT_IDENTITY` | 403 | `.planLimitIdentity(limit:Int?, current:Int?)` | 「無料プランで登録できる名義は \(limit) 件までです」 |
| `PLAN_LIMIT_SHARE` | 403 | `.planLimitShare(limit:Int?, current:Int?)` | 「無料プランで作れる共有リンクは \(limit) 本までです」 |
| **`PLAN_LIMIT_SHARE_WRITE`** | 403 | **`.planLimitShareWrite(limit:Int?, current:Int?)`** | 「編集を許可する共有は \(limit) 公演までです（このツアーは \(current) 公演）。読み取り専用で共有するか、Plus をご検討ください」 |
| `NOT_FOUND` | 404 | `.notFound` | 「対象が見つかりません。一覧を更新してください」 |
| `SHARE_INVALID` | 404 | `.shareInvalid` | 「この共有リンクは無効です」（`PATCH /public/...` で受けた場合は「共有が終了しているか、表が更新されています」+ 再取得を促す） |
| **`EMAIL_ALREADY_REGISTERED`** | 409 | **`.emailAlreadyRegistered`** | 「このメールアドレスは既に登録されています。ログインしてください」 |
| `CONFLICT` | 409 | `.conflict` | 「すでに登録されています。一覧を更新してください」 |
| `CONFLICT`（共有ボードの `rev` 不一致） | 409 | **`.shareItemConflict(current: SharedItemSnapshot)`** | 「他の人が先に更新しました。最新の内容に更新しました」+ 行を `current` で描き直す |
| **`RATE_LIMITED`** | 429 | **`.rateLimited`** | 「試行回数が上限に達しました。しばらく待ってからお試しください」 |
| `INTERNAL` | 500 | `.server` | 「サーバーエラーが発生しました。時間をおいて再試行してください」 |
| 上記以外 | any | **`.unknown(code:String, message:String)`** | 「エラーが発生しました（\(code)）」 |
| envelope でない / デコード失敗 | any | `.decoding(String)` | 「応答を解釈できませんでした」 |
| `URLError` | — | `.offline` / `.timeout` / `.transport(URLError)` | §Q11 の表 |

`.shareItemConflict` の扱い（**重要**）:

- `CONFLICT` は「既存 id への POST」と「共有 item の `rev` 不一致」の 2 用途で共用される。
- **汎用マッパーは常に `.conflict` を返す。** `details.current` を読んで `.shareItemConflict` に格上げするのは
  `RemoteSharedBoardRepository` だけ（文脈を知っているのはそこだけ）。汎用側に `details` の形を知らせない。
- `details.current` は `{ status, seat, rev }`（`api-contract-delta.md` §4）。デコードに失敗したら `.conflict` に留める。

`.rateLimited` は **自動リトライしない**（§1「リトライしない」の原則どおり）。ユーザーの明示操作でのみ再試行。

**`.unknown` を既知ケースに丸めない。** これが BE-2（未知 enum の黙殺フォールバック）の iOS 版。
`request_id` は全ケースで保持し、`AppLogger` に `code` と一緒に出す（**`message` の本文はログに出さない** — 個人情報が混ざりうる）。

`PLAN_LIMIT_*` の `details` は `{ limit: Int, current: Int }`。**`details` の欠落・型不一致でクラッシュさせない**（欠落時は `limit`/`current` を `nil` にし、文言を「無料プランの上限に達しました」にフォールバック）。

---

## 3. Domain モデルの変更（before → after）

`meigicho/Packages/Domain/Sources/Domain/Models/Models.swift`。**この変更は T0 が唯一の編集者**（`plan.md` §3）。

### 3.1 `Identity`

| フィールド | before | after | 理由 |
|---|---|---|---|
| `id` | `UUID` | 変更なし | — |
| `displayName` | `String` | 変更なし | — |
| `relation` | `Relation` | 変更なし | E7（enum 生値一致） |
| `colorHex` | `String` | 変更なし（API `color`） | — |
| `joinedOn` | `Date?` | 変更なし | — |
| `historyVisible` | `Bool = true` | **`Bool = false`** | Q9・`docs/03` §4.4 |
| `note` | `String` | **`String`**（API は `note: String?` → `?? ""` で受け、送信時は空文字を `nil` に） | 既存 UI が非 Optional 前提 |
| **`sortOrder`** | 無し | **`Int = 0`（追加）** | F4 |
| `memberships` | `[Membership]` | **削除**（`MembershipStore` が `identityID` で引く） | BE は別エンドポイント。ネストを維持すると PATCH 単位とズレる |
| **`updatedAt`** | 無し | **`Date`（追加）** | 表示はしないが将来の同期・デバッグ用 |

`memberships` を外すため `AppDataStore.expiringMembershipCount` / `sortedIdentities(by:.renewalSoon)` /
`IdentityListView` の FC 名表示が影響を受ける（`plan.md` T0 で `IdentityStore` に集約）。

### 3.2 `Membership`

| フィールド | before | after |
|---|---|---|
| `id` | `UUID` | 変更なし |
| **`identityID`** | 無し | **`UUID`（追加）** |
| `fcName` | `String` | **`fanClubNameRaw: String`（改名）** — API `fan_club_name_raw` と揃える |
| `memberNo` | `String`（平文） | **`memberNoLast4: String?`** — Q8・C5 |
| **`rank`** | 無し | **`String?`（追加）** |
| `renewalOn` | `Date` | **`Date?`** — E2 |
| `annualFee` | `Int` | **`feeYen: Int?`（改名 + Optional）** — E2 |
| **`autoRenew`** | 無し | **`Bool = false`（追加）** |
| **`note`** | 無し | **`String`（追加、API は `note: String?`）** |

### 3.3 `Companion`

| フィールド | before | after |
|---|---|---|
| **`id`** | 無し | **`UUID`（追加）** — F1・PATCH 全置換に必須 |
| `identityID` | `UUID?` | 変更なし |
| `name` | `String` | **`displayName: String`（改名）** — API `display_name` |
| **`position`** | 無し | **`Int`（追加）** — API は `position asc` で返す |

### 3.4 `ApplicationEntry`

| フィールド | before | after |
|---|---|---|
| `id` | `UUID` | 変更なし |
| `tourName` | `String` | **削除** → `tourID: UUID` に置換（表示名は `Tour` から引く。F5） |
| **`tourID`** | 無し | **`UUID`（追加）** |
| **`eventID`** | 無し | **`UUID`（追加）** |
| `eventName` / `venueName` | `String` | **削除** → `EventEntity` から引く |
| `artistName` | `String` | **削除** → `Tour.artistNameRaw` から引く |
| `eventOn` | `Date` | **削除** → `EventEntity.eventDate: Date?` から引く（F3・E-8） |
| `repIdentityID` | `UUID` | 変更なし |
| **`repMembershipID`** | 無し | **`UUID?`（追加、当面常に nil）** — FR-AP-7 |
| **`roundName`** | 無し | **`String?`（追加）** |
| `appliedOn` / `resultOn` | `Date?` | 変更なし |
| `status` | `ApplicationStatus` | 変更なし（E7） |
| `seatRaw` | `String` | 変更なし |
| **`ticketCount`** | 無し | **`Int = 1`（追加）** |
| **`priceYen`** | 無し | **`Int?`（追加）** |
| `companions` | `[Companion]` | 変更なし（型は 3.3） |
| `note` | `String` | 変更なし |
| **`updatedAt`** | 無し | **`Date`（追加）** |

### 3.5 新規 Domain 型

```
Tour        : id, name, artistNameRaw, updatedAt
EventEntity : id, tourID, name, venueNameRaw, eventDate: Date?, startsAt: Date?, updatedAt
UserProfile : userID, accountID: String?, displayName: String?, username: String?,
              appDisplayName: String?, themeColor: String, locale: String, timezone: String,
              onboardedAt: Date?, email: String?, authProviders: [String]
Entitlement : plan: Plan, expiresAt: Date?, inGracePeriod: Bool,
              bonusIdentitySlots: Int, bonusExpiresAt: Date?,
              identityLimit: Int?, shareLimit: Int?      // null = 無制限
ShareLink   : id, scopeType: ShareScope, scopeID: UUID?, scopeName: String?,
              permission: SharePermission,                 // ← 追加
              maskMemberNo: Bool, sharedWithAccountIDs: [String],
              expiresAt: Date?, revokedAt: Date?,
              viewCount: Int, lastViewedAt: Date?,
              editCount: Int, lastEditedAt: Date?,         // ← 追加
              createdAt: Date, isActive: Bool
              // token / url は発行レスポンスにのみ存在。ShareLink には持たせず、
              // 発行時だけ IssuedShareLink(link:, token:, url:) で返す（C4）

// --- 共有ボード（受け取り側）。ApplicationEntry とは別系統の型 ---
SharedBoard     : permission: SharePermission,
                  tourName: String?, artistName: String?,   // tour スコープのときだけ入る
                  generatedAt: Date,
                  content: SharedBoardContent
                  // scopeType は content から導出（保存しない）
SharedBoardContent : case tour([SharedBoardItem])
                   | case identitySummary([SharedIdentitySummaryItem])   // §4.8 P7
SharedBoardItem : rowIndex: Int,              // レスポンス内の並び順（行 id の一意化に使う）
                  eventName: String, venue: String?, eventDate: Date?, roundName: String?,
                  repName: String, repColor: String?, companions: [String],
                  status: ApplicationStatus, seat: String?,
                  handle: SharedItemHandle?     // nil = read リンク or 編集不可
SharedItemHandle: itemKey: String, rev: String, editable: Bool   // 3 つで 1 単位（§4.8 P2）
SharedIdentitySummaryItem : rowIndex: Int, name: String, counts: SharedIdentityCounts?
                            // counts == nil = visible:false（非公開）。**0 件と混同しない**
SharedIdentityCounts : applicationCount: Int, wonCount: Int   // 2 つで 1 単位（§4.8 P8）
SharedItemSnapshot : status: ApplicationStatus, seat: String?, rev: String  // 409 の details.current
```

**`SharedBoard*` は内部 UUID を持たない。** `ApplicationEntry` / `Identity` に変換しない（§4.8 P6）。

新規 enum（生値は 2 本の契約と一致させる。**変更禁止**）:

```
Plan            : free | plus
ShareScope      : tour | identity_summary
SharePermission : read | write            // ← write は api-contract-delta.md §0 で追加
```

`ViewMode` などの UI 専用 enum は既存どおり `AppEnums.swift`。

### 3.6 `EventEntity` の命名

`docs/05` §2.1 に従い `Event` ではなく **`EventEntity`**（`EventKit.EKEvent` / `UIEvent` との混同回避）。
`Tour` / `Companion` / `Identity` / `Membership` / `ApplicationEntry` はサフィックス無し。

---

## 4. エンドポイント別 DTO

DTO は `Packages/Network/Sources/Network/DTO/` に置く。すべて `Decodable` / `Encodable` を明示分離
（レスポンス用 `*Response` と リクエスト用 `*Request` を別型にする。1 型を双方向に使うと PATCH の省略制御が壊れる）。

### 4.1 Auth

ログイン方式は **Apple / Google / メール+パスワードの 3 系統**（Q3 の判断が覆り、Google とメールを追加）。
`user` を含むレスポンスは **4 経路とも完全に同形**（`apple` / `google` / `register` / `login` / `password/reset`）。
DTO を 1 つ（`AuthSessionResponse`）に共通化し、リクエストだけ経路ごとに分ける。

| API | 認証 | Request DTO | Response |
|---|---|---|---|
| `POST /v1/auth/apple` | Public | `AppleSignInRequest { identity_token, nonce? }` | 200 `AuthSessionResponse` |
| **`POST /v1/auth/google`** | Public | **`GoogleSignInRequest { id_token, nonce? }`** | 200 `AuthSessionResponse` |
| **`POST /v1/auth/register`** | Public | **`RegisterRequest { email, password }`** | **201** `AuthSessionResponse`（`user.is_new` は常に `true`） |
| **`POST /v1/auth/login`** | Public | **`LoginRequest { email, password }`** | 200 `AuthSessionResponse`（`user.is_new` は常に `false`） |
| **`POST /v1/auth/password`** | **Bearer 必須** | **`ChangePasswordRequest { current_password, new_password }`** | 200 **`TokenPairResponse`**（user 無し） |
| **`POST /v1/auth/password/reset-request`** | Public | **`ResetRequestRequest { email }`** | **202 / ボディ無し** |
| **`POST /v1/auth/password/reset`** | Public | **`ResetPasswordRequest { email, code, new_password }`** | 200 `AuthSessionResponse`（`user.is_new` は常に `false`） |
| `POST /v1/auth/refresh` | Public | `RefreshRequest { refresh_token }` | 200 `TokenPairResponse` |
| `POST /v1/auth/logout` | Public | `LogoutRequest { refresh_token }` | 204 |

```
AuthSessionResponse {
  access_token, refresh_token, expires_in, token_type,
  user { id, account_id, display_name, plan, is_new }
}
TokenPairResponse { access_token, refresh_token, expires_in, token_type }
```

Domain: `AuthSession(accessToken, refreshToken, expiresAt: Date, user: SignedInUser)` /
`TokenPair(accessToken, refreshToken, expiresAt: Date)`。

**契約上の落とし穴（実装エージェントが踏みやすい順）**:

| # | 内容 |
|---|---|
| A1 | **Apple は `identity_token`、Google は `id_token`。キー名が違う**（`api-contract-delta.md` §1。Google SDK の命名に合わせた意図的な差） |
| A2 | `nonce` は Apple / Google とも **サーバー側でハッシュしない単純比較**。iOS は認可リクエストに設定したのと同じ文字列をそのまま送る（Q4 と同じ扱い） |
| A3 | `register` だけ **201**。他は 200。ステータスコードでの分岐を書くなら間違えない |
| A4 | `reset-request` は **202 / ボディ無し**。「メールを送りました」を UI に出してよいが、**登録の有無は分からない**（アカウント列挙防止で常に同じ応答）。「登録されていれば送信しました」という文言にする |
| A5 | `POST /v1/auth/password` 成功時、**サーバーがその user の refresh token を全件失効させ新しい 1 本を返す**。iOS は返ってきたペアで Keychain を必ず上書きする。上書きし忘れると自分自身が次の refresh でログアウトする |
| A6 | `password/reset` 成功時も同様に全件失効 + 新ペア。**そのままログイン状態にする**（追加のログイン操作を求めない） |
| A7 | `login` の 401 は未登録・パスワード誤り・パスワード未設定を**区別しない**。iOS も区別して表示しない |
| A8 | `code` は **8 桁の数字**（`^\d{8}$`）。入力欄は `keyboardType(.numberPad)` + 8 文字上限 |
| A9 | `password` は **8〜128 文字・文字種要件なし**。iOS で独自の複雑さバリデーション（大文字必須など）を足さない（IOS-4） |
| A10 | `email` は 255 文字以下。正規化（`trim().toLowerCase()`）は**サーバーがやる**。iOS は trim だけして送る |
| A11 | レート制限あり（`login`/`register`/`password` は 10 回/5 分、`reset-request` は **3 回/15 分**、`reset` は 10 回/15 分）。429 は `.rateLimited`。**自動リトライしない** |

`expires_in`（秒）は受信時刻 + `expires_in - 60`（60 秒のマージン）を `expiresAt` にして保持し、
**期限前でも 401 は起こりうる**前提で FR-N-6 の再送を必ず残す。

#### 4.1.1 Google の `id_token` をどう取るか（iOS 側の取得経路）

BE が受け取るのは Google の **OpenID Connect id_token** で、`aud` が `GOOGLE_CLIENT_IDS` に含まれる必要がある
（`api-contract-delta.md` §0）。iOS 側の取得方法は `plan.md` §7.2 で決定する（**第三者 SDK を追加しない自前実装を採用**）。
本書が固定するのは **BE に渡す値の形**だけ:

- `id_token`: Google が返した JWT をそのまま。**加工しない**
- `nonce`: 認可リクエストの `nonce` パラメータに入れたのと**同じ文字列**（A2）
- `aud` は iOS 用 OAuth クライアント ID になる。**この値が BE の `GOOGLE_CLIENT_IDS` に入っていること**が動作条件。設定の食い違いは `AUTH_GOOGLE_INVALID` 401 として現れ、iOS 側からは原因が見えない。**環境構築手順に明記する**

### 4.2 Me

| API | Request | Response |
|---|---|---|
| `GET /v1/me` | — | `MeResponse { user{ id, email, auth_providers, created_at }, profile{ account_id, display_name, username, app_display_name, theme_color, locale, timezone, onboarded_at, created_at, updated_at }, entitlement{ plan, expires_at, in_grace_period, bonus_identity_slots, bonus_expires_at, identity_limit, share_limit } }` |
| `PATCH /v1/me` | `UpdateMeRequest { display_name?, username?, app_display_name?, theme_color?, locale?, timezone?, onboarded_at? }` | `MeResponse` |

**`account_id` / `plan` / `id` を Request DTO に入れない**（C6・`forbidNonWhitelisted` で 400）。
`theme_color` は `^#[0-9A-Fa-f]{6}$`。`ThemeStore` の `hexString` が `#RRGGBB` 大文字を返すことを確認済み（`ThemeColor.swift`）。

**`user.auth_providers` の意味が変わった**（`api-contract-delta.md` §2）。キー名・型は不変（`[String]`）だが導出規則が更新された:

| 値 | 条件 |
|---|---|
| `"apple"` | `apple_sub` あり |
| `"google"` | `google_sub` あり |
| `"email"` | **`password_hash` あり**（旧: `email` 列の有無） |

順序は `apple` → `google` → `email` で固定。iOS 側の用途:

- アカウント設定に「連携済みのログイン方法」を表示する
- **`auth_providers` に `"email"` が含まれるときだけ「パスワードを変更」を出す。** 含まれないのに `POST /v1/auth/password` を叩くと `FORBIDDEN` 403
- `Relation` 等と同じく **未知の文字列が増えてもクラッシュしない**（`[String]` のまま持ち、表示は既知 3 値のみラベル化。未知値は無視してログに残す）

### 4.3 Identities

| API | Request | Response |
|---|---|---|
| `GET /v1/identities?include_deleted=false` | — | `{ items: [IdentityResponse] }` |
| `POST /v1/identities` | `CreateIdentityRequest { id, display_name, relation?, color?, joined_on?, note?, history_visible?, sort_order? }` | `IdentityResponse`（201） |
| `PATCH /v1/identities/:id` | `UpdateIdentityRequest`（同フィールド・`id` 抜き・全任意） | `IdentityResponse` |
| `DELETE /v1/identities/:id` | — | 204 |

`IdentityResponse { id, display_name, relation, color, joined_on, note, history_visible, sort_order, created_at, updated_at, deleted_at }`

### 4.4 Memberships

| API | Request | Response |
|---|---|---|
| `GET /v1/memberships` | — | `{ items: [MembershipResponse] }`（`identity_id` 未指定 = 自分の全件） |
| `POST /v1/memberships` | `CreateMembershipRequest { id, identity_id, fan_club_name_raw, member_no_last4?, rank?, renewal_on?, fee_yen?, auto_renew?, note? }` | `MembershipResponse`（201） |
| `PATCH /v1/memberships/:id` | `UpdateMembershipRequest`（`identity_id` の付け替え可・全任意） | `MembershipResponse` |
| `DELETE /v1/memberships/:id` | — | 204 |

`MembershipResponse { id, identity_id, fan_club_name_raw, member_no_last4, rank, renewal_on, fee_yen, auto_renew, note, created_at, updated_at, deleted_at }`

**`member_no` / `member_no_cipher` を Request DTO に定義しない**（送ると 400。型として存在させない）。

### 4.5 Tours / Events

| API | Request | Response |
|---|---|---|
| `GET /v1/tours` | — | `{ items: [TourResponse] }` |
| `PATCH /v1/tours/:id` | `UpdateTourRequest { name?, artist_name_raw? }` | `TourResponse` |
| `DELETE /v1/tours/:id` | — | 204 |
| `GET /v1/events` | — | `{ items: [EventResponse] }` |
| `PATCH /v1/events/:id` | `UpdateEventRequest { name?, venue_name_raw?, event_date?, starts_at? }` | `EventResponse` |
| `DELETE /v1/events/:id` | — | 204 |
| `GET /v1/tours/:id/matrix` | — | `TourMatrixResponse`（**今回は使わない** — ツアー表はローカル集計で足りる。DTO も作らない） |

`POST /v1/tours` / `POST /v1/events` は**存在しない**（C3）。Repository に create メソッドを生やさない。

### 4.6 Applications

| API | Request | Response |
|---|---|---|
| `GET /v1/applications?limit=200&cursor=<opaque>` | — | `{ items: [ApplicationResponse], next_cursor: String?, has_more: Bool }` |
| `POST /v1/applications` | `CreateApplicationRequest`（下記） | `ApplicationResponse`（201） |
| `PATCH /v1/applications/:id` | `UpdateApplicationRequest { rep_identity_id?, rep_membership_id?, round_name?, applied_on?, result_on?, status?, seat_raw?, ticket_count?, price_yen?, note?, companions? }` | `ApplicationResponse` |
| `DELETE /v1/applications/:id` | — | 204 |

```
CreateApplicationRequest {
  id, tour { id, name, artist_name_raw? },
  event { id, name, venue_name_raw?, event_date?, starts_at? },
  rep_identity_id, rep_membership_id?, round_name?, applied_on?, result_on?,
  status?, seat_raw?, ticket_count?, price_yen?, note?,
  companions: [{ id, identity_id?, display_name, position }]
}
ApplicationResponse {
  id, tour_id, event_id, rep_identity_id, rep_membership_id, round_name,
  applied_on, result_on, status, seat_raw, ticket_count, price_yen, note,
  companions: [{ id, identity_id, display_name, position }],
  created_at, updated_at, deleted_at
}
```

**`ApplicationResponse` は tour / event の名前を含まない。** iOS は `tours` / `events` を別途取得して join する（FR-AP-1）。
`event_id` に対応する `EventEntity` が手元に無い場合（他端末で追加された直後など）は
**「公演情報を読み込み中」を出し、`GET /v1/events/:id` を単発で引いて埋める**。名前を空文字で描かない。

`cursor` は `next_cursor` をそのまま次リクエストの `cursor` に渡す。**中身を解釈しない**（C7）。

### 4.7 Shares（オーナー側・Bearer 必須）

| API | Request | Response |
|---|---|---|
| `POST /v1/shares` | `CreateShareRequest { scope_type, scope_id?, permission?, mask_member_no?, expires_at?, shared_with_account_ids? }` | `CreateShareResponse { id, token, url, scope_type, scope_id, permission, mask_member_no, shared_with_account_ids, expires_at, created_at }`（201） |
| `GET /v1/shares` | — | `{ items: [ShareResponse] }` |
| `DELETE /v1/shares/:id` | — | 204 |

```
ShareResponse {
  id, scope_type, scope_id, scope_name, permission, mask_member_no,
  shared_with_account_ids, expires_at, revoked_at,
  view_count, last_viewed_at,
  edit_count, last_edited_at,          // ← 追加（api-contract-delta.md §3）
  created_at, is_active
}
```

- `id` は **Request に含めない**（サーバー生成）
- `scope_type == "identity_summary"` のとき **`scope_id` を送ってはいけない**（送ると 400）
- **`permission`: `"read"` / `"write"`。省略時 `"read"`**。未知値は 400（黙って `read` に落とさない = BE-2）
- **`"write"` は `scope_type: "tour"` のみ。** `identity_summary` と組み合わせたら 400
- 上 2 つの制約は **型レベルで潰す**:
  ```
  enum ShareScopeSelection: Sendable {
    case tour(UUID, permission: SharePermission)   // read / write
    case identitySummary                            // scope_id も permission も送らない
  }
  enum SharePermission: String, Sendable { case read, write }
  ```
  `identitySummary` からは `scope_id` / `permission` のキー自体が生成されない `Encodable` 実装にする
- `shared_with_account_ids` は各 `^ACC-[0-9A-F]{6}$`・最大 20 件。`TourShareStore.parseAccountIDs`（`TourShareStore.swift:143-147`）を残しつつ**正規表現バリデーションを追加**し、不正な ID は送信前に UI で弾く
- `token` / `url` は `CreateShareResponse` にのみ存在（C4）。`ShareResponse` に定義しない（型として持たせない）
- **write 発行は公演数上限を持つ**（free = 3 公演 / plus = 無制限）。超過は `PLAN_LIMIT_SHARE_WRITE` 403（`details: {limit, current}`）。
  **iOS 側で 3 をハードコードして事前に弾かない**（IOS-4）。押させて 403 を文言化する。`GET /v1/me` の `entitlement` にこの上限は含まれない
- **発行後に `permission` を変更する API は無い。** 変更 = `DELETE` して再発行

Domain 型（`ShareLink`）に `editCount: Int` / `lastEditedAt: Date?` / `permission: SharePermission` を追加する。

### 4.8 Public（共有ボード・**Bearer 不要 / token のみ**）

**Q7 の判断が覆り、iOS からもこの経路を呼ぶ。** 共有リンクを受け取った人が、
アプリで表を開いて **状況と座席だけ**編集できる（`api-contract-delta.md` §4）。

| API | 認証 | Request | Response |
|---|---|---|---|
| `GET /public/shares/:token` | **無し** | — | `SharedBoardResponse` |
| `PATCH /public/shares/:token/items/:item_key` | **無し** | `UpdateSharedItemRequest { rev, status?, seat? }` | `SharedBoardItemResponse`（更新後 1 件） |

**`/v1` プレフィックスを付けない**（`app.setup.ts` の `GLOBAL_PREFIX_EXCLUDE`）。`Endpoint` に「プレフィックス無し」の表現を持たせる。

**`scope_type` によって items の形が完全に別物**（`api-contract.md` §8 の 2 つの JSON 例 /
`apps/api/src/public/public-share.presenter.ts` の `TourSharePayload` と `IdentitySummaryPayload`）。
**同じ型で両方を受けようとしない**（tour の非 Optional キーを付けると identity_summary が必ずデコード失敗する）。

`scope_type == "tour"`:

```
SharedBoardResponse {
  scope_type: "tour",
  permission,                       // "read" | "write" ← 追加
  tour { name, artist_name },
  generated_at,
  items: [SharedBoardItemResponse]
}
SharedBoardItemResponse {
  event_name, venue, event_date, round_name,
  rep_name, rep_color, companions: [String], status, seat,
  // ↓ permission == "write" のときだけ現れる
  item_key?, rev?, editable?
}
```

`scope_type == "identity_summary"`:

```
SharedBoardResponse {
  scope_type: "identity_summary",
  permission,                       // 常に "read"（書き込み経路が無い）
  generated_at,
  items: [SharedIdentitySummaryItemResponse]
  // **`tour` キーは存在しない**
}
SharedIdentitySummaryItemResponse {
  name, visible,
  // ↓ visible == true のときだけ現れる（visible:false は**キーごと来ない**）
  application_count?, won_count?
}
```

実物（`api-contract.md:627-637`）:

```json
{
  "scope_type": "identity_summary",
  "generated_at": "2026-08-02T10:00:00.000Z",
  "items": [
    { "name": "自分", "visible": true, "application_count": 12, "won_count": 5 },
    { "name": "友人A", "visible": false }
  ]
}
```

| キー | 型 | 意味 |
|---|---|---|
| `permission` | `"read"` / `"write"` | 編集 UI を出すかの判定。`identity_summary` にも付く（常に `read`） |
| `item_key` | `String`（base64url 22 文字） | 書き込み対象の不透明ハンドル。**リンクごとに異なる**。**解釈・生成しない** |
| `rev` | `String`（base64url 16 文字） | 楽観ロックトークン。**解釈しない**。GET で受け取った値をそのまま PATCH に返す |
| `editable` | `Bool` | `false` の行は PATCH が 403。**理由（プラン超過か非公開名義か）はサーバーが区別しない** |

**マッピング規則（守ること）**:

| # | 規則 |
|---|---|
| P1 | `permission == "read"` のとき `item_key` / `rev` / `editable` は**キーごと存在しない**。Optional で受け、`nil` を「編集不可」として扱う。**`editable ?? true` にしない** |
| P2 | Domain 型は `SharedBoardItem { eventName, venue, eventDate: Date?, roundName: String?, repName, repColor: String?, companions: [String], status: ApplicationStatus, seat: String?, handle: SharedItemHandle? }`。`SharedItemHandle { itemKey: String, rev: String, editable: Bool }` を **1 つの Optional にまとめる**ことで「itemKey はあるが rev が無い」という不整合状態を型で作れなくする |
| P3 | `item_key` / `rev` は内部 UUID を復元できない不透明値。**`Identifiable.id` にそのまま使ってよい**（リンク内で一意） |
| P4 | `status` は `draft`/`applied`/`won`/`lost`/`cancelled` の 5 値。未知値は `.applied` にフォールバックしログに残す（E-12） |
| P5 | `seat` は `null` / 空文字 / 文字列の 3 状態。**空文字を `null` に丸めない**（サーバーは空文字を空文字として保存する） |
| P6 | `SharedBoardItem` に **内部 UUID・会員番号・`identity_id`・`account_id` は含まれない**。Domain の `ApplicationEntry` / `Identity` へ変換しようとしない（**別の型として扱う**） |
| P7 | **`scope_type` で items のデコード経路を分ける**。トップレベルの `scope_type` を先に読み、`tour` / `identity_summary` の 2 系統に分岐する。Domain 側も `SharedBoardContent`（enum）で持ち、「identity_summary なのに tour の行がある」状態を型で作れなくする。未知の `scope_type` は**どちらにも落とさずデコード失敗**（BE-2 の iOS 版）。`identity_summary` の `permission` はキーが欠けたら**最も制限の強い `read`**（tour では欠けたら失敗させる） |
| P8 | identity_summary の `visible: false` は **`application_count` / `won_count` のキー自体が来ない**。Optional で受け、`SharedIdentityCounts?` の `nil` を「非公開」として扱う。**0 件と書かない**。`visible` と件数の有無が食い違う契約違反はマスキング側（非公開）に倒し、ログに残す |
| P9 | read リンクには `item_key` が無く、`round_name` 違い・非公開名義のマスク（`rep_name` が全て `"非公開の名義"`）で**行の内容だけでは一意にならない**。`Identifiable.id` にはレスポンス内の並び順（`rowIndex`）を含める（`ForEach` の id 重複防止） |

**`PATCH` のリクエスト**:

```
UpdateSharedItemRequest { rev: String, status: String?, seat: String? }
```

- `rev` 必須。`status` / `seat` は**少なくとも一方が必須**（両方無いと 400）
- **上記 3 キー以外を送ったら 400**（`forbidNonWhitelisted`）。`round_name` / `note` / `companions` などを送らない
- `seat` は「送らない」と「`null` を送る」を区別する必要がある
- 「少なくとも一方」を型で強制する:
  ```
  enum SharedItemChange: Sendable {
    case status(ApplicationStatus)
    case seat(String?)                        // nil = 明示的な null
    case statusAndSeat(ApplicationStatus, String?)
  }
  ```
  この enum からしか `UpdateSharedItemRequest` を作れないようにする（空ボディを型で作れなくする）

**エラー（判定順序が契約。`api-contract-delta.md` §4 の表）**:

| 状況 | code / HTTP | iOS の挙動 |
|---|---|---|
| トークン未知 / 失効 / 期限切れ | `SHARE_INVALID` 404 | ボード全体を「この共有は終了しました」に切り替える。保存したトークンを破棄 |
| `permission != "write"` / `editable: false` | `FORBIDDEN` 403 | 行を元に戻し「この行は編集できません」。**理由を推測して説明しない** |
| `item_key` 不一致 | `SHARE_INVALID` 404 | ボードを再取得（表が変わった可能性） |
| `rev` 不一致 | `CONFLICT` 409 + `details.current` | `.shareItemConflict(current:)` → **その行だけ** `current` の値と新しい `rev` で描き直し「他の人が先に更新しました」を出す。**ボード全体を再取得しない** |
| レート超過（60 回/分） | `RATE_LIMITED` 429 | 「操作が多すぎます。少し待ってください」。自動リトライしない |

**iOS はこの経路に `Authorization` ヘッダを付けない**（§5 の `SharedBoardRepository` / `PublicApiClient` を使う理由。詳細は §5.1）。

---

## 5. Repository protocol（`Domain/Repositories/`）

```
protocol AuthRepository: Sendable {
  // ソーシャル
  func signInWithApple(identityToken: String, nonce: String?) async throws -> AuthSession
  func signInWithGoogle(idToken: String, nonce: String?) async throws -> AuthSession

  // メール + パスワード
  func register(email: String, password: String) async throws -> AuthSession
  func login(email: String, password: String) async throws -> AuthSession
  func changePassword(current: String, new: String) async throws -> TokenPair   // Bearer 必須
  func requestPasswordReset(email: String) async throws                          // 202 / 戻り値なし
  func resetPassword(email: String, code: String, newPassword: String) async throws -> AuthSession

  // トークン
  func refresh(refreshToken: String) async throws -> TokenPair
  func logout(refreshToken: String) async throws
}
protocol ProfileRepository: Sendable {
  func fetchMe() async throws -> MeSnapshot            // (UserProfile, Entitlement)
  func updateMe(_ patch: ProfilePatch) async throws -> MeSnapshot
}
protocol IdentityRepository: Sendable {
  func list() async throws -> [Identity]
  func create(_ identity: Identity) async throws -> Identity
  func update(id: UUID, _ patch: IdentityPatch) async throws -> Identity
  func delete(id: UUID) async throws
}
protocol MembershipRepository: Sendable {
  func list() async throws -> [Membership]
  func create(_ membership: Membership) async throws -> Membership
  func update(id: UUID, _ patch: MembershipPatch) async throws -> Membership
  func delete(id: UUID) async throws
}
protocol CatalogRepository: Sendable {                  // tours + events（作成メソッドは持たない = C3）
  func listTours() async throws -> [Tour]
  func listEvents() async throws -> [EventEntity]
  func fetchEvent(id: UUID) async throws -> EventEntity
  func updateTour(id: UUID, _ patch: TourPatch) async throws -> Tour
  func updateEvent(id: UUID, _ patch: EventPatch) async throws -> EventEntity
}
protocol ApplicationRepository: Sendable {
  func listPage(limit: Int, cursor: String?) async throws -> ApplicationPage   // (items, nextCursor, hasMore)
  func create(_ draft: ApplicationDraft) async throws -> ApplicationEntry
  func update(id: UUID, _ patch: ApplicationPatch) async throws -> ApplicationEntry
  func delete(id: UUID) async throws
}
protocol ShareRepository: Sendable {                    // オーナー側・Bearer 必須
  func list() async throws -> [ShareLink]
  func create(_ selection: ShareScopeSelection,
              maskMemberNo: Bool,
              sharedWithAccountIDs: [String]) async throws -> IssuedShareLink   // token / url を含む
  func revoke(id: UUID) async throws
}

/// 共有ボード（受け取り側）。**Bearer を使わない。token が唯一の資格情報。**
protocol SharedBoardRepository: Sendable {
  func fetchBoard(token: String) async throws -> SharedBoard
  func updateItem(token: String,
                  itemKey: String,
                  rev: String,
                  change: SharedItemChange) async throws -> SharedBoardItem
}
```

- **`Domain` は `Foundation` のみ import する。** `URLSession` / `Security` / `SwiftData` を入れない（NFR-5）
- `*Patch` 構造体は §1.2 の `Patchable<T>` を使い、「送らない」と「null を送る」を型で区別する
- `Network` の `Remote*Repository` が唯一の実装。テスト・Preview 用の `InMemory*Repository` を `Domain/Preview/` に置く（`SampleData` の行き先）
- `ShareRepository.create` は `ShareDraft` 構造体をやめ **`ShareScopeSelection` を第 1 引数**にした（§4.7）。
  「`identity_summary` なのに `scope_id` / `permission` が入っている」draft を作れなくするため

### 5.1 `SharedBoardRepository` を分ける理由（設計判断）

共有ボードの 2 経路（`GET /public/shares/:token` / `PATCH /public/shares/:token/items/:item_key`）は
**Bearer 認証を使わない。** 資格情報は URL パス中の token だけで、共有先は自分のアカウントでログインしていない前提。

**採用**: `Domain` に `SharedBoardRepository` を独立して置き、`Network` に **`PublicApiClient`（`ApiClient` とは別の型）** を作って実装する。

| 分ける理由 | 内容 |
|---|---|
| 1 | **`ApiClient` は全リクエストに `Authorization` を付ける**（§1 の共通ヘッダ）。公開経路に付けるのは無意味かつ、ログインしていない受け取り側では付ける値が無い |
| 2 | **`ApiClient` は 401 で refresh → 失敗ならサイレントログアウトする**（FR-N-6）。公開経路が返す 401 系（`AUTH_*`）は本来ありえないが、万一 401 が返ったときに**共有ボードを見ただけのユーザーが自分のアカウントからログアウトさせられる**。認証状態と公開経路を配線で結んではいけない |
| 3 | **`/v1` プレフィックスを付けない**（`GLOBAL_PREFIX_EXCLUDE`）。`ApiClient` に例外分岐を持ち込むと、他のエンドポイントでプレフィックス漏れを起こしやすい |
| 4 | **token は Bearer とライフサイクルが違う**（回転しない・失効はサーバー都合・複数本を同時に持ちうる）。`TokenStore` と混ぜない |

`PublicApiClient` の仕様:

- `ApiClient` とエラー変換ロジック（envelope → `AppError`）だけ共有し、**トークン注入と 401 リトライを持たない**
- リトライを一切しない
- token をログに出さない（`AppLogger` には `code` と `request_id` のみ）

**受け取った共有トークンの保管**（`SharedBoardTokenStore`）:

- token は「そのボードを読み書きできる」capability。**UserDefaults に置かない**（平文で iCloud バックアップに載る）
- **Keychain**（`kSecAttrAccessibleAfterFirstUnlock`）に、`TokenStore`（自分の refresh token）とは**別の service / account 名前空間**で複数本保存する
- 保存するのは `token` と、表示用の最小メタ（ツアー名・最終取得時刻）。**サーバーから来た表データはキャッシュしない**（Q1 のとおりローカル永続化を持たない方針と揃える）
- `SHARE_INVALID` 404 を受けたら**その token を Keychain から破棄**する

**却下案**: `ApiClient` に `requiresAuth: Bool` フラグを足して 1 つのクライアントで両対応する案。
フラグ 1 つの付け忘れが「公開経路に Bearer を送る」「認証経路に Bearer を送らない」の両方向の事故になり、
かつ理由 2（誤ログアウト）を型で防げない。**型を分けてコンパイル時に混同できなくする**ほうが安い。

---

## 6. BE 側の変更が必要になりうる箇所（現時点では **変更不要**）

| # | 箇所 | 状態 / 変更が要る条件 |
|---|---|---|
| B1 | Apple / Google の nonce 平文比較（`apple-token.verifier.ts:123-129` と Google 側の同等処理） | **確定済み（Q4 = 平文送信）。BE 変更なし。** ハッシュ方式に変えるなら BE 差分計画が必要 |
| B2 | `GET /v1/applications` のページング | 4,000 件超のユーザーが実在した場合。今回は打ち切り表示で凌ぐ（FR-AP-2） |
| ~~B3~~ | ~~共有トークンの再取得~~ | **解消。** write 共有は `item_key` / `rev` で解決し、トークン再取得は不要になった（`api-contract-delta.md` §4）。オーナー側は自分のデータを直接見るのでボードを開く必要が無い |
| B4 | `home/summary` / `stats/identities` | ホームの集計をサーバーに寄せる場合（今回はローカル集計・スコープ外） |
| **B5** | `GET /v1/me.entitlement` に **`share_write_event_limit` が無い** | write 共有の公演数上限（free=3）を発行前に UI で示したくなった場合。**今回は 403 を受けてから文言化する**ので変更不要 |
| **B6** | 共有ボードの Universal Links 対応（`share.example.com` の `apple-app-site-association`） | 受け取り側が URL タップでアプリに入る導線を作る場合。**今回はカスタムスキーム + URL 貼り付けまで**（roadmap 1-7 の Next.js 共有 Web と同時にやる） |
| **B7** | `PATCH /public/shares/:token/items/:item_key` の対象フィールド拡張 | 共有先に `round_name` / `note` / 同行者の編集を開放する場合。**契約上は意図的に閉じている**ので拡張要求が出たら BE 差分計画へ |

**いずれかに該当したら本計画を止め、BE 側の差分計画を先に立てる。iOS 実装エージェントが BE を触らない。**
