# requirements — ios-network-integration

iOS クライアント（`meigicho/`）を NestJS API に接続する。
契約の正は `docs/plans/backend-domain-modules/api-contract.md`（変更しない）。
本計画で新たに確定するのは **iOS 側の DTO ↔ Domain マッピング**（`contract-mapping.md`）。

未確定事項は `questions-requirements.md`（Q1〜Q14、`[Assumed]` で暫定確定済み）。

---

## 1. 現状把握（ギャップ分析）

### 1.1 実装済みのもの

| 層 | 状態 |
|---|---|
| BE | 9 モジュール実装済み・Prisma モック単体テストあり・実 DB 疎通確認済み（`make up && make health`）。`/v1` プレフィックスと除外は `apps/api/src/app.setup.ts:4-11` |
| iOS Features | HTML モック 14 画面すべて実装済み（`Packages/Features/Sources/Features/**`、計 1,822 行）。遷移・シート・タブは配線済み |
| iOS DesignSystem | トークン・コンポーネント実装済み。エラー表示資産は `FormHint(isError:)` / `EmptyStateView` / `DS.error` バッジの 3 つ |
| iOS Core | `Color+Hex` / `DateFormatting`（JST 固定カレンダー） / `ThemeColor` の 3 ファイルのみ |

### 1.2 欠けているもの

| # | ギャップ | 現物 |
|---|---|---|
| G1 | `Network` パッケージが存在しない | `meigicho/project.yml:8-16` の packages は Core/DesignSystem/Domain/Features のみ |
| G2 | `DataStore` パッケージが存在しない | 同上（→ Q1 で今回スコープ外と判断） |
| G3 | Repository protocol が 1 つも無い。`Features → Domain ← Network` の依存図が未成立 | `Packages/Domain/Sources/Domain/` |
| G4 | `AppDataStore` が完全インメモリ。`SampleData` 初期値に毎起動巻き戻る | `AppDataStore.swift:11-21` |
| G5 | `AuthStore` が Google / メールのモック。BE は Apple のみ | `AuthStore.swift:33-56` |
| G6 | `TourShareStore` が UserDefaults の擬似共有。**共有先が編集できる**前提で作られている | `TourShareStore.swift:121-141`、`ApplicationListView.swift:303-358` |
| G7 | Domain モデルが契約と非互換（会員番号平文・companion に id 無し・tour/event ID 無し・historyVisible 既定不一致 ほか） | `Models.swift`（詳細は `contract-mapping.md` §3） |
| G8 | `UUIDv7` が無い。クライアント発行 UUID が全 POST で必須 | `Packages/Core/Sources/Core/` |
| G9 | `AppDataStore.today` が 2026-07-31 固定 | `AppDataStore.swift:15` |
| G10 | 接続先設定（`API_BASE_URL`）・ATS・Keychain 保管が無い | `App/Info.plist` |
| G11 | Free 名義上限（`PLAN_LIMIT_IDENTITY` 403）の受け口が無い | Features を grep して 0 件 |

### 1.3 死にコードの確認（本 skill ①「死んでいるコードを手本にしない」）

- `Features` の 14 画面はすべて `MainTabView` → タブ / `path.append` / `SheetPresenter` から到達可能。**死にコードは無い**（呼び出し元を `grep` で確認済み）
- したがって Domain モデルの型を変えると **必ず 14 画面のどこかがコンパイルエラーになる**。これは望ましい（IOS-2 をコンパイラに検出させる）

---

## 2. 機能要件

### FR-N: Network 基盤

| ID | 要件 |
|---|---|
| FR-N-1 | `Packages/Network` を新設し、`URLSession` + `async/await` で `/v1/*` を叩く `ApiClient` を持つ。**第三者ライブラリを追加しない** |
| FR-N-2 | 全リクエストに `Authorization: Bearer <access_token>` と `X-Request-Id`（クライアント生成 UUID v7）を付ける。`X-Request-Id` はエラー envelope にそのまま返るのでログ突合に使う |
| FR-N-3 | JSON キーは snake_case。**`keyDecodingStrategy = .convertFromSnakeCase` は使わず、DTO ごとに `CodingKeys` を明示する**（BE のフィールド改名を grep で追える形にする = IOS-2 対策） |
| FR-N-4 | 日付は 2 種類（`YYYY-MM-DD` と ISO8601 UTC ミリ秒）。**単一の `dateDecodingStrategy` では両立しないため、DTO では両方 `String` で受け、マッパーで `Core` の変換関数を通す** |
| FR-N-5 | エラー envelope（`code` / `message` / `details` / `request_id`）をデコードし `AppError` に変換する。**未知の `code` は `.unknown(code:message:)` にし、既知のどれかに黙って落とさない**（BE-2 の iOS 版） |
| FR-N-6 | 401 `UNAUTHENTICATED` で 1 回だけ refresh → 再送。refresh は actor で直列化し、並行 401 でも 1 回しか走らない。refresh 失敗（`AUTH_REFRESH_INVALID`）で サイレントログアウト |
| FR-N-7 | `Domain` の Repository protocol を実装した `Remote*Repository` を提供する。`Network` は `Domain` と `Core` にのみ依存する |
| FR-N-8 | `Features` は `Network` を import しない。具象注入は Composition Root（`App/MeigichoApp.swift`）のみ（IOS-5） |

### FR-AUTH: 認証

| ID | 要件 |
|---|---|
| FR-AUTH-1 | **【rev.2 で変更】** ログイン手段は **Apple + Google + メール+パスワードの 3 方式**（Q3 の判断が覆り「撤去しない」に確定）。App Store Guideline 4.8 は Sign in with Apple を提供し続けることで満たす。既存の `GoogleSignInButton` / `LoginDivider` は**削除しない** |
| FR-AUTH-2 | `ASAuthorizationAppleIDProvider` で取得した `identityToken` を `POST /v1/auth/apple` に送り、`access_token` / `refresh_token` / `user` を得る |
| **FR-AUTH-2b** | **Google の `id_token` を `POST /v1/auth/google` に送る（キー名は `id_token`。Apple の `identity_token` と違う）。取得方法は Q15（自前 `ASWebAuthenticationSession` + PKCE を推奨）** |
| **FR-AUTH-2c** | **メール+パスワード: `POST /v1/auth/register`（201）/ `login` / `password`（Bearer 必須）/ `password/reset-request`（202・ボディ無し）/ `password/reset`。契約は `contract-mapping.md` §4.1** |
| **FR-AUTH-2d** | **`POST /v1/auth/password` と `password/reset` は成功時にサーバーが refresh token を全件失効させ新ペアを返す。返ってきたペアを Keychain に必ず上書きする**（保存漏れ = 自分自身のログアウト） |
| FR-AUTH-3 | nonce は **`request.nonce` に設定したのと同じ文字列**を送る（ハッシュしない。Q4・BE の実装 `apple-token.verifier.ts:123-129` に合わせる）。**Google も同じ扱い** |
| FR-AUTH-4 | refresh token は Keychain（`kSecAttrAccessibleAfterFirstUnlock`）。access token はメモリのみ（Q6） |
| FR-AUTH-5 | 起動時に Keychain の refresh token で `POST /v1/auth/refresh` を試み、成功なら自動ログイン。失敗ならログイン画面（Q5） |
| FR-AUTH-6 | ログアウトは `POST /v1/auth/logout`（204・冪等）→ Keychain クリア → メモリ上の全データ破棄 |
| FR-AUTH-7 | `AuthenticationServices` の import は `Features/Account` に閉じる。`Domain` / `Network` は `identityToken: String` しか知らない |
| FR-AUTH-8 | `is_new == true` の場合の初回オンボーディング分岐は**今回は使わない**（オンボーディング画面が存在しない）。値は受け取るだけにし、無視することをコードコメントに書く |

### FR-ME: プロフィール / アカウント

| ID | 要件 |
|---|---|
| FR-ME-1 | ログイン後に `GET /v1/me` を取得し、`account_id` / `username` / `app_display_name` / `theme_color` / `entitlement` を保持する |
| FR-ME-2 | `AccountView` の ユーザーネーム / アプリ名 / 背景カラーの変更を `PATCH /v1/me` に送る。**入力のたびに送らず、フォーカス喪失時（`@FocusState`）または 800ms デバウンス後に 1 回**送る |
| FR-ME-3 | `account_id` はサーバー値を表示する。`AuthStore.generateAccountID`（クライアント生成モック）を削除する |
| FR-ME-4 | `theme_color` を `ThemeStore.apply(hex:)` に流し込み、端末間でテーマ色が揃うようにする。UserDefaults キャッシュは起動直後のちらつき防止として残す |
| FR-ME-5 | `entitlement.identity_limit`（`free` は 3、`plus` は `null`）を保持する。**iOS 側で 3 をハードコードしない**（IOS-4） |

### FR-ID: 名義 / 会員情報

| ID | 要件 |
|---|---|
| FR-ID-1 | 一覧 `GET /v1/identities`（`include_deleted=false`）。並びはサーバー順（`sort_order asc, created_at asc`）を初期値とし、既存の 3 ソートは従来どおり iOS 側で並べ替える |
| FR-ID-2 | 追加 `POST /v1/identities`。`id` は **UUID v7 をクライアントで発行**して送る。`history_visible` の既定は **`false`**（Q9） |
| FR-ID-3 | 推しカラー変更 / 備考編集 / 履歴公開トグルは `PATCH /v1/identities/:id`（変更フィールドのみ送る） |
| FR-ID-4 | `PLAN_LIMIT_IDENTITY` 403 を受けたら `details.limit` / `details.current` を使って「無料プランで登録できる名義は N 件までです」と表示する。**ペイウォールは出さない**（Q2） |
| FR-ID-5 | 会員情報は `GET /v1/memberships`（全件取得後に `identity_id` でグルーピング）。追加は `POST /v1/memberships`（`id` はクライアント発行） |
| FR-ID-6 | 会員番号は **下 4 桁のみ** (`member_no_last4`)。入力欄を「会員番号の下4桁（任意）」に変更し、自動切り出しはしない（Q8） |
| FR-ID-7 | `renewal_on` / `fee_yen` は nullable。「更新日未設定」「年会費未設定」を表示できるようにする（E2） |

### FR-AP: 申込 / ツアー / 公演

| ID | 要件 |
|---|---|
| FR-AP-1 | 起動時に `identities` / `memberships` / `tours` / `events` を並行取得し、`applications` は `limit=200` + `cursor` で `has_more == false` まで反復取得する（Q10） |
| FR-AP-2 | 反復は 20 ページ（4,000 件）で打ち切り、`truncated` フラグを立ててホームに 1 行出す。**黙って切らない** |
| FR-AP-3 | 申込追加は `POST /v1/applications`（tour / event の find-or-create をサーバーに任せる）。`id` / `tour.id` / `event.id` / `companions[].id` はすべてクライアントで UUID v7 発行 |
| FR-AP-4 | ツアー名サジェストは取得済み `tours` の `name` から前方/部分一致。**同名を選んだ場合も `tour.id` は新規発行してよい**（サーバーが `ownerId_name` で find-or-create するため）。ただし既存 tour を選んだときは既知の `tour.id` を送る（無駄な UUID を生まない） |
| FR-AP-5 | ステータス変更 / 座席編集は `PATCH /v1/applications/:id`（当該フィールドのみ）。当選→落選に戻しても `seat_raw` は送らない（消さない。`docs/05` R3-3） |
| FR-AP-6 | 同行者は 0〜3 件。`identity_id` の重複は送信前に弾く（サーバーも 400 を返すが、UI で先に防ぐ） |
| FR-AP-7 | `rep_membership_id` は **本計画では常に `null`** を送る（現在の `AddApplicationView` に会員情報を選ぶ UI が無い）。UI を足すのは別計画。`PATCH` で `rep_identity_id` を変えるとサーバーが自動クリアする挙動（`api-contract.md` §7）に依存してよい |
| FR-AP-8 | ツアーのグルーピングキーを **ツアー名 → `tourID`** に変更する（F5）。表示名は `tours[tourID].name` |
| FR-AP-9 | `event_date` が null の申込を扱えるようにする（`eventOn: Date?`、ソートは `?? .distantFuture`） |

### FR-SH: 共有

| ID | 要件 |
|---|---|
| FR-SH-1 | `TourShareStore` を `POST /v1/shares` / `GET /v1/shares` / `DELETE /v1/shares/:id` に置き換える。UserDefaults 永続化を廃止 |
| FR-SH-2 | **【rev.2 で変更】** 共有ボードの編集機能は**撤去しない**（Q7 の判断が覆った）。BE の write 権限に接続する。ただし**オーナー側のツアー表はローカルデータ一本**にし、編集は通常の申込 PATCH 経路にする。共有先の編集画面は **FR-SB-\*** で別建て |
| **FR-SH-2b** | **`POST /v1/shares` に `permission`（`read` / `write`、省略時 `read`）を送る。`write` は `scope_type: "tour"` のみ。公演数上限（free = 3）超過は `PLAN_LIMIT_SHARE_WRITE` 403 を文言化する（iOS 側で 3 をハードコードして事前に弾かない = IOS-4）** |
| **FR-SH-2c** | **`GET /v1/shares` の `edit_count` / `last_edited_at` をツアー行に表示する（`閲覧 N 回 ・ 編集 M 回`）** |
| FR-SH-3 | 発行時に `scope_type: "tour"` / `scope_id: <tourID>` / `mask_member_no: true` / `shared_with_account_ids` を送る。`expires_at` は送らない（サーバー既定 +30 日） |
| FR-SH-4 | 生 URL は発行レスポンスでしか得られない。メモリ保持中のみ「リンクをコピー」を出し、再起動後は「共有中（リンクは再取得できません）」+「共有を停止して作り直す」を出す（C4。**この制約は rev.2 でも不変**） |

### FR-SB: 共有ボード（受け取り側・**Bearer 不要 / token のみ**）— rev.2 で新設

| ID | 要件 |
|---|---|
| FR-SB-1 | `GET /public/shares/:token` でボードを取得し、`PATCH /public/shares/:token/items/:item_key` で **`status` / `seat` だけ**を更新する |
| FR-SB-2 | **この経路に `Authorization` を付けない。`ApiClient` / `TokenStore` を経由しない。** 専用の `PublicApiClient` + `SharedBoardRepository` を使う（`contract-mapping.md` §5.1）。**`ApiClient` の 401 refresh 経路に繋ぐと、ボードを見ただけのユーザーが自分のアカウントからログアウトする** |
| FR-SB-3 | `item_key` / `rev` は不透明値。**解釈も生成もしない**。GET で受けた `rev` をそのまま PATCH に返す |
| FR-SB-4 | `permission == "read"` のとき `item_key` / `rev` / `editable` はキーごと存在しない。**`editable ?? true` にしない**（read リンクで編集 UI が出る事故） |
| FR-SB-5 | `CONFLICT` 409（`rev` 不一致）は `details.current` で**その行だけ**再描画する。ボード全体を再取得しない |
| FR-SB-6 | `editable: false` の理由（非公開名義 / プラン超過）は**サーバーが区別しない**。iOS も推測して説明しない |
| FR-SB-7 | 受け取った共有 token は **Keychain**（自分の refresh token とは別 service 名前空間）に保存する。**UserDefaults 不可**。`SHARE_INVALID` 404 で破棄する（Q17） |
| FR-SB-8 | エントリポイントは **カスタムスキーム `meigicho://share/<token>` + URL 貼り付け**まで。Universal Links はスコープ外（Q16・roadmap 1-7） |
| FR-SB-9 | `SharedBoardItem` を `ApplicationEntry` / `Identity` に変換しない（内部 UUID を持たない別系統の型） |
| FR-SH-5 | `GET /v1/shares` の `is_active` / `view_count` / `expires_at` / `revoked_at` をツアー行に表示する |
| FR-SH-6 | `PLAN_LIMIT_SHARE` 403 を「無料プランで作れる共有リンクは 1 本までです」と表示する |
| FR-SH-7 | `SharePreviewView` の `historyVisible` トグルは FR-ID-3 の `PATCH /v1/identities/:id` に接続する。プレビューの件数表示はローカル集計のまま |

---

## 3. 非機能要件

| ID | 要件 |
|---|---|
| NFR-1 | Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`、`project.yml:24`) 下でビルドが通る。`@unchecked Sendable` を新規に増やさない（既存 Store の `@unchecked` は `@MainActor` 化で解消を試み、無理なら理由をコメントする） |
| NFR-2 | UI 更新は `@MainActor`。ネットワーク I/O は非分離 async。`Repository` protocol は `Sendable` |
| NFR-3 | 起動から初回描画までネットワークをブロックしない（`docs/05` §9）。ログインゲートの判定（refresh 1 往復）だけは待つが、その間はプレースホルダを描く |
| NFR-4 | 秘密情報（access / refresh token・**Google の `id_token` / 認可 `code`・共有 token・パスワード・リセットコード**）を `print` / `os_log` に出さない。エラーログに出すのは `request_id` と `code`（エラーコード）のみ |
| NFR-5 | `Features` → `Network` / `DataStore` の直接依存を作らない（IOS-5）。`Domain` に URLSession / Security を import しない |
| NFR-6 | 依存追加ゼロ（`Package.swift` の `dependencies` にリモートパッケージを足さない）。**rev.2 注記**: Google 認証の追加でこの制約が争点になる。**Q15 の推奨（`ASWebAuthenticationSession` + PKCE の自前実装）を採れば維持できる**。`GoogleSignIn-iOS` SDK を入れる判断に変わる場合は**本行を改訂してから**実装する（実装者の独断で追加しない — plan.md R8） |

---

## 4. 制約

| # | 制約 | 出典 |
|---|---|---|
| C1 | API 契約は `backend-domain-modules/api-contract.md` が正。iOS 都合で変えない。変更が要るなら BE 側の差分計画を先に立てる | rule 02 |
| C2 | ID は UUID（クライアント発行 v7 前提。サーバーはバージョンを検証しない） | `api-contract.md` §0 |
| C3 | `POST /v1/tours` / `POST /v1/events` は存在しない。tour / event の作成経路は `POST /v1/applications` の find-or-create のみ | `api-contract.md` §9 D9 |
| C4 | 共有の生トークンは発行時 1 回だけ。再取得手段は無い | `api-contract.md` §8 |
| C5 | `member_no`（平文）は送れない。`member_no_last4` のみ | `api-contract.md` §4 |
| C6 | `PATCH /v1/me` に読み取り専用キー（`account_id` / `plan` / `id`）を含めると 400（`forbidNonWhitelisted`） | `api-contract.md` §2 |
| C7 | `cursor` は opaque。クライアントが解釈・生成しない | `api-contract.md` §0 |
| C8 | enum 値は `relation` / `status` / `plan` / `scope_type` / `permission` の 5 つ。iOS の既存 enum 生値は BE と一致済み（E7）。**変更しない** | `api-contract.md` §0 |

---

## 5. エッジケース

| # | ケース | 期待挙動 |
|---|---|---|
| E-1 | 空データ（名義 0 / 申込 0） | 既存の `EmptyStateView` がそのまま出る。エラー表示と区別する（「読み込めませんでした」と「まだありません」を混同しない） |
| E-2 | POST の id 重複（`CONFLICT` 409） | UUID v7 の再発行はしない。「保存に失敗しました（既に登録されています）」を出し、再取得を促す。**黙って PATCH に切り替えない** |
| E-3 | 親 identity を消した後にその名義を代表とする申込 | サーバーはソフトデリートで申込を連鎖削除しない（`api-contract.md` §3・§5）。iOS は `identities` に無い `rep_identity_id` を「削除済みの名義」と表示して落ちないこと |
| E-4 | membership の `identity_id` 付け替えでサーバーが `rep_membership_id` を自動クリア | 本計画は `rep_membership_id` を常に null で送るので影響なし（FR-AP-7）。ただし PATCH レスポンスをそのまま反映すること（ローカルで推測しない） |
| E-5 | access token の期限切れが並行 5 リクエスト中に起きる | refresh は 1 回だけ。全リクエストが同じ新トークンで再送される（FR-N-6） |
| E-6 | refresh token を別端末のログインで回転させられた | `AUTH_REFRESH_INVALID` → サイレントログアウト。データ損失は無い（サーバーが正） |
| E-7 | オフライン中の書き込み | 送信せずエラー表示。キューに積まない（Q1）。UI の値は編集前に戻す |
| E-8 | `event_date` が null の申込 | ソートは末尾。日付表示は「未定」（`DateFormatting.formatDateShort` は既に nil で「未定」を返す） |
| E-9 | 申込 4,000 件超 | 20 ページで打ち切り + 明示表示（FR-AP-2） |
| E-10 | タイムゾーン | `YYYY-MM-DD` は JST 00:00 に正規化して `Date` にし、送信時も JST カレンダーで `YYYY-MM-DD` に戻す。既存 `Core/DateFormatting` の JST 固定カレンダーと一致させる（`docs/05` §6） |
| E-11 | 共有リンクの期限切れ | `is_active == false` を「共有終了」表示にする。`GET /v1/shares` は失効済みも返す（`revoked_at` 付き） |
| E-12 | サーバーが未知の enum 値を返す | `Relation(rawValue:) ?? .other` / `ApplicationStatus(rawValue:) ?? .applied` でクラッシュさせない（`docs/05` §2.2）。ただし**フォールバックしたことをログに残す** |

---

## 6. 影響範囲（層チェックリスト）

| 層 | 対象 |
|---|---|
| DB | **変更なし**（BE 実装済み・schema 変更を伴わない） |
| BE | **変更なし**。Q4 でハッシュ nonce を選んだ場合のみ `apple-token.verifier.ts` に差分が出る → その場合は本計画を止めて BE 差分計画へ |
| iOS Core | `UUIDv7.swift`（新規）/ `APIDateFormat.swift`（新規）/ `Nonce.swift`（新規）/ `Package.swift`（`.macOS(.v14)` + testTarget） |
| iOS Domain | `Models.swift`（型変更）/ `AppDataStore.swift`（分割）/ `AuthStore.swift`（全面書き換え）/ `TourShareStore.swift`（全面書き換え）/ `Repositories/`（新規）/ `AppError.swift`（新規）/ `Mapping/`（新規）/ `SampleData.swift`（Preview 専用へ降格） |
| iOS Network | パッケージ新規（`ApiClient` / `TokenStore` / `Endpoint` / `DTO/` / `Remote*Repository`） |
| iOS DesignSystem | `ErrorBar.swift`（新規）。`GoogleSignInButton` / `LoginDivider` は参照が消えるなら削除 |
| iOS Features | 14 画面すべて（Domain 型変更に追従）。特に `AccountView`（ログイン UI 総入れ替え）と `ApplicationListView`（共有ボード撤去） |
| App | `MeigichoApp.swift`（Composition Root）/ `Info.plist`（`API_BASE_URL` + ATS） |
| project.yml | `Network` パッケージ追加・App target 依存追加・configs 追加 |
| docs | 実装後に `docs/05-ios-client.md`（Network 節・AppRoute サンプル・SwiftData 前提の位置づけ）と `CLAUDE.md`（iOS 追従状況・検証ゲート）を更新 |

---

## 7. スコープ外（再掲・`questions-requirements.md` Q2 が正）

SwiftData / オフライン書き込み / 同期エンジン / ペイウォール / StoreKit / AdMob / ローカル通知 / 統計画面 /
Next.js 共有 Web / APNs / Google・メール認証 / `.xcconfig` の環境分離完全整備。
