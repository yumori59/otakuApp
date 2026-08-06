# requirements — backend-auth-and-shares-extension

**対象**: `apps/api`（NestJS + Prisma）への 2 つの追加

1. 認証プロバイダの追加（**Google Sign-In** / **Email + Password**）— Sign in with Apple に**併設**する
2. 共有リンク **Phase 2（共同編集 = write 権限）**

**前提**: `docs/plans/backend-domain-modules/` は実装済み・レビュー済み・実 DB 疎通確認済み。
**契約の正**: 既存分は `docs/plans/backend-domain-modules/api-contract.md`、本計画の追加分は同ディレクトリの `api-contract-delta.md`。
**確定状況（2026-08-02）**: `questions-requirements.md` の **Q1〜Q8 は回答済み**。Q9（ロードマップ追記）のみ `[Assumed]` のまま進行をユーザーが承認。**本計画は着手可能な状態にある。**

回答により当初案から変わった点は 2 つ:

1. **Q1**: パスワードリセットを**スコープに含める**（メール送信は **Resend**）。当初は「メール基盤未選定のため範囲外」としていた
2. **Q3**: write 共有のプラン差を「発行可否」から「**1 本あたりの公演数上限**」に変更。Free も write 共有を発行できる

---

## 1. 現状把握（実装着手前に確認した事実）

| # | 事実 | 出典 |
|---|---|---|
| F1 | `users.google_sub` は**既に存在する**（`String? @unique`）。Google 用のスキーマ追加は不要 | `apps/api/prisma/schema.prisma:13` |
| F2 | パスワード用の列は**無い**。`users.email` は nullable かつ**一意制約なし** | `schema.prisma:14` |
| F3 | Apple の identity token 検証は `jose` を使わず `node:crypto` で RS256 を自前実装している（jest の CJS 環境と非互換だったため）。JWKS キャッシュ・未知 kid の強制再取得 cooldown 付き | `auth/apple-token.verifier.ts` / `auth/apple-jwks.provider.ts:30` |
| F4 | `AuthService.findOrCreateAppleUser` は「sub で検索 → 無ければ users + profiles + entitlements を 1 TX で作成 → P2002 なら読み直して `is_new:false`」。Google / メール登録もこの形に揃える | `auth/auth.service.ts:62-101` |
| F5 | refresh は回転式。DB には sha256 のみ保存 | `auth/auth.service.ts:137-193` |
| F6 | `GET /v1/me.auth_providers` は DB 列を増やさず `apple_sub` / `google_sub` / `email` から**導出**している。現在の実装は「apple も google も無く email がある → `email`」 | `me/me.service.ts:186-196` |
| F7 | `ShareLink.permission` は `String @default("read")`。**列は既にあり、値の検証は DTO 側**。`SharesService.create` は `permission: 'read'` をハードコードしている | `schema.prisma:217` / `shares/shares.service.ts:55` |
| F8 | 公開ペイロードのマスキングは `public/public-share.presenter.ts` に集約され、「**内部 UUID を一切出さない**」が明文の不変条件になっている。したがって公開 write の対象行を `application_id` で指定させることはできない | `public/public-share.presenter.ts:4-14` |
| F9 | 公開ビューは `TourMatrixService.build()` の行を再利用している。行に `updated_at` は**含まれていない** | `tours/tour-matrix.service.ts:8-30` |
| F10 | `ApplicationsService` は `assertOwned` / `applyUpdate` / `transaction` を公開し、`ApplicationsModule` は `ApplicationsService` を **export 済み**。公開 write から再利用できる（新規サービスを作らない） | `applications/applications.module.ts:22` |
| F11 | レート制限は**存在しない**（`@nestjs/throttler` 未導入）。`AllExceptionsFilter` は HttpException を `errorCodeFromStatus` で写すが 429 のケースが無い | `package.json` / `common/errors/error-codes.ts:42-57` |
| F12 | `/v1` を外すルートは `app.setup.ts` の `GLOBAL_PREFIX_EXCLUDE` にリテラルで列挙されている。公開 write のパスもここに足さないと `/v1/public/...` になる | `app.setup.ts:7-11` |
| F13 | `src` が読む環境変数は `docker-compose.yml` の `api.environment` と**厳密一致**していないとテストが落ちる（過不足どちらも失敗） | `config/env-coverage.spec.ts` |
| F14 | iOS 側（`docs/plans/ios-network-integration/`）は T1（認証）と T4（共有）を**本計画の契約確定待ちで停止中** | 同 `questions-requirements.md:77,155` |
| F15 | `EntitlementsService` は `@Global` で、`identityLimit(userId)` / `shareLimit(userId)` が「Free は数値・Plus は `null`（無制限）」を返すパターンで実装されている。公演数上限も同じ形にできる | `entitlements/entitlements.service.ts` / `me/me.service.ts:121-125` |
| F16 | メール送信の依存・抽象・env は**一切存在しない**（`resend` も `nodemailer` も無い） | `apps/api/package.json` |
| F17 | `refresh_tokens` は「生トークンは返すだけ・DB は `sha256Hex` のみ・`revoked_at` で失効」という形。**リセットコードもこの形を踏襲できる** | `auth/auth.service.ts:137-193` / `common/util/hash.util.ts` |

### ギャップ分析

| 機能 | DB | BE | iOS |
|---|---|---|---|
| Google Sign-In | ○（`google_sub`） | ×（検証器・エンドポイント無し） | モック UI あり（`AccountView`） |
| Email + Password | ×（列が無い） | × | モック UI あり |
| 共有 write | △（`permission` 列はあるが `read` 固定） | ×（公開は GET のみ） | モック UI あり（`ApplicationListView` 共有テーブル） |

---

## 2. 機能要件

### 2.1 Google Sign-In（FR-GA）

| # | 要件 |
|---|---|
| FR-GA-1 | `POST /v1/auth/google`（Public）は Google の id_token を JWKS で検証する。署名(RS256) / `iss` / `aud` / `exp` を必須検証し、リクエストが `nonce` を送ってきたときのみ `nonce` も検証する（Apple と同じ作法 — ios 側 Q4 の決定に揃える） |
| FR-GA-2 | `iss` は `https://accounts.google.com` と `accounts.google.com` の**どちらも受理**する（Google が両方を発行するため）。`GOOGLE_ISSUER` を設定した場合はその値のみ |
| FR-GA-3 | `aud` は `GOOGLE_CLIENT_IDS`（カンマ区切り）のいずれかに一致すること。**未設定なら 500**（検証の素通しを作らない） |
| FR-GA-4 | 検証失敗は理由に依らず `AUTH_GOOGLE_INVALID` 401（存在・原因を漏らさない） |
| FR-GA-5 | `google_sub` で find-or-create。新規時は users + profiles(`account_id` 採番) + entitlements(`free`) を 1 TX で作る（F4 と同形） |
| FR-GA-6 | `email` は **`email_verified === true` のときだけ** `users.email` に保存する。既存ユーザーの `email` は上書きしない（Apple と同じ「初回のみ」） |
| FR-GA-7 | レスポンスは `POST /v1/auth/apple` と**同一形状**（`access_token` / `refresh_token` / `expires_in` / `token_type` / `user{ id, account_id, display_name, plan, is_new }`） |
| FR-GA-8 | JWKS の取得・キャッシュ・未知 kid の強制再取得 cooldown は Apple と同一実装を共有する（コピーしない） |

### 2.2 Email + Password（FR-EP）

| # | 要件 |
|---|---|
| FR-EP-1 | `POST /v1/auth/register`（Public）: `email` + `password` で新規ユーザーを作る。レスポンスは Apple と同一形状・`is_new: true` |
| FR-EP-2 | 識別子は `users.email_normalized`（`trim` + `toLowerCase`、`@unique`）。`users.email` には入力された元の値を入れる（表示用） |
| FR-EP-3 | 既に同じ `email_normalized` があれば `EMAIL_ALREADY_REGISTERED` 409。**ユーザー列挙のリスクを承知の上で採用**（メール送信が無いため「常に 200 を返して確認メール」戦略が取れない）。緩和策はレート制限（Q7） |
| FR-EP-4 | パスワードは `scrypt`（Q8 の形式）で保存。**平文をログ・エラーメッセージ・DB に一切残さない** |
| FR-EP-5 | パスワード長は 8〜128 文字。文字種の複雑さ要件は課さない（NIST SP 800-63B）。email は `class-validator` の `@IsEmail()` + 255 文字上限 |
| FR-EP-6 | `POST /v1/auth/login`（Public）: 成功で Apple と同一形状・`is_new: false` |
| FR-EP-7 | ログイン失敗（未登録 email / パスワード不一致 / `password_hash` が null のユーザー）は**すべて同一の** `AUTH_CREDENTIALS_INVALID` 401（message も同一文字列） |
| FR-EP-8 | パスワード照合は `timingSafeEqual`。ユーザーが見つからない場合もダミーハッシュに対して照合を実行し、応答時間差でアカウントの存在を漏らさない |
| FR-EP-9 | `POST /v1/auth/password`（**Bearer 必須**）: `current_password` を検証して `new_password` に変更する。成功時、**その user の既存 refresh token を全件失効**させ、新しいトークンペアを返す |
| FR-EP-10 | `password_hash` が null（Apple / Google のみ）のユーザーが FR-EP-9 を呼んだら `FORBIDDEN` 403。**OAuth アカウントへのパスワード追加はアカウント統合（Q2）と同じ扱いで本計画の範囲外** |
| FR-EP-11 | `GET /v1/me.auth_providers` の導出を `password_hash` の有無に基づくよう変更する（F6 の「email 列があれば email」は誤判定になる） |
| FR-EP-12 | ログイン成功時、保存されている scrypt パラメータが現行既定と異なれば再ハッシュして保存する（将来の強化に備える） |

### 2.2b パスワードリセット（FR-PR）— Q1 の回答で追加

| # | 要件 |
|---|---|
| FR-PR-1 | `POST /v1/auth/password/reset-request`（Public）は email を受け取り、**登録の有無に関わらず 202 + 空ボディ**を返す（アカウント列挙を防ぐ） |
| FR-PR-2 | 送信対象は `email_normalized` が一致し **かつ `password_hash` が非 null** のユーザーのみ。Apple / Google だけのアカウントにはメールを送らない（パスワードを持たないため。パスワード追加は Q2 のアカウント統合と同じ扱いで範囲外） |
| FR-PR-3 | リセットコードは **8 桁の数字**。DB には `sha256(userId + ':' + code)` のみを保存し、平文は**メール本文にしか存在しない**（DB・ログ・レスポンス・例外メッセージに出さない） |
| FR-PR-4 | 有効期限 15 分。発行時に同一ユーザーの未使用コードをすべて失効させる（有効なのは常に最新 1 本） |
| FR-PR-5 | `POST /v1/auth/password/reset`（Public）は `email` + `code` + `new_password` を受け取る。成功したら 200 でトークンペア + user を返す（ログイン済みにする） |
| FR-PR-6 | 検証失敗（未知 email / 誤コード / 期限切れ / 使用済み / 試行超過）は**すべて同一の** `AUTH_RESET_CODE_INVALID` 401（message も同一） |
| FR-PR-7 | 誤コード 5 回で当該コード行を失効させる（`attempt_count`）。以後は正しいコードでも 401 |
| FR-PR-8 | リセット成功時、同一 TX で ①`password_hash` / `password_updated_at` を更新 ②当該コードを `used_at` ③**その user の refresh token を全件失効** ④その user の他の未使用コードを失効 — したうえで新しいトークンペアを発行する |
| FR-PR-9 | メール送信は `MailSender` 抽象（DI トークン）越しに行う。テストはスタブに差し替え、**jest からネットワークに出ない** |
| FR-PR-10 | 本番（`NODE_ENV=production`）で `RESEND_API_KEY` 未設定なら送信時に `INTERNAL` 500。**コードをログにフォールバック出力しない**。非本番かつ未設定のときのみ、ローカル開発用にコードをログ出力してよい |
| FR-PR-11 | メール本文にはコード・有効期限・「心当たりがない場合は無視してよい」旨を含める。会員番号・名義名など他の個人情報を含めない |
| FR-PR-12 | `reset-request` は登録の有無で処理時間が大きく変わらないようにする（未登録でも同等の処理を通してから 202 を返す） |

### 2.3 共有リンク Phase 2 / write（FR-SW）

| # | 要件 |
|---|---|
| FR-SW-1 | `POST /v1/shares` が `permission`（`read` / `write`、省略時 `read`）を受理する。未知値は 400（BE-2）。**省略時の挙動は既存契約と同一**（後方互換） |
| FR-SW-2 | `permission: "write"` は `scope_type: "tour"` のみ。`identity_summary` との組み合わせは 400 |
| FR-SW-3 | **`permission: "write"` はどのプランでも発行できる**（Q3）。ただし Free は「1 本の write 共有に含められる公演数」に上限がある。`EntitlementsService.shareWriteEventLimit(userId)` は Free で `3`、Plus で `null`（無制限）を返す |
| FR-SW-3a | `POST /v1/shares` で `permission:"write"` のとき、対象 tour の**未削除 event 数**が上限を超えていたら `PLAN_LIMIT_SHARE_WRITE` 403（`details: { limit, current }`）。`read` はこの制限を受けない |
| FR-SW-3b | 同時有効リンク数の上限（`PLAN_LIMIT_SHARE`）は read / write を区別せず従来どおり数える |
| FR-SW-3c | **発行後に公演が増えた場合**、既存リンクは有効のまま。公演順（`event_date asc nulls last, event_name asc`）で先頭 N 公演の行だけ `editable: true` とし、超過分は閲覧のみ（PATCH は `FORBIDDEN` 403）。判定は**閲覧・更新の都度**行うため、Plus → Free のダウングレードにも自動追従する |
| FR-SW-4 | `GET /public/shares/:token` のペイロード最上位に `permission` を返す（閲覧側が編集 UI を出すかの判定に使う） |
| FR-SW-5 | `permission: "write"` のときだけ、tour ペイロードの各 item に `item_key` と `rev` を含める。read リンクのペイロードは**現行とバイト等価**（キーが増えない） |
| FR-SW-6 | `item_key` は**内部 UUID を露出しない不透明値**で、リンクごとに異なる。`hmac_sha256(key = share_links.token_hash, msg = "item:" + application.id)` の base64url 先頭 22 文字 |
| FR-SW-7 | `rev` は楽観ロック用の不透明値。`hmac_sha256(key = token_hash, msg = "rev:" + application.id + ":" + application.updated_at.toISOString())` の base64url 先頭 16 文字。**`updated_at` そのものは公開しない** |
| FR-SW-8 | `PATCH /public/shares/:token/items/:item_key`（Public）で `status` / `seat` を更新できる。`rev` は必須 |
| FR-SW-9 | 認可の判定順と応答: ①トークン無効 → `SHARE_INVALID` 404 ②`permission !== "write"` → `FORBIDDEN` 403 ③`item_key` 不一致 → `SHARE_INVALID` 404 ④`editable: false` の行（`history_visible=false` **または**公演数上限の超過分）→ `FORBIDDEN` 403 ⑤`rev` 不一致 → `CONFLICT` 409（`details` に現在値） |
| FR-SW-9a | ④の 403 では**理由を区別しない**（`PLAN_LIMIT_SHARE_WRITE` を公開エンドポイントで返さない）。未認証の相手にオーナーの課金状態を漏らさない |
| FR-SW-10 | 更新は既存の `ApplicationsService.assertOwned` + `applyUpdate` を `link.owner_id` スコープで再利用する（新しい書き込み経路を作らない・BE-3 / BE-4） |
| FR-SW-11 | 成功レスポンスは**更新後の公開 item 1 件**（`public-share.presenter.ts` と同じマスキング関数を通す）。内部 UUID を含めない |
| FR-SW-12 | 成功時に `share_links.edit_count += 1` / `last_edited_at = now()`。`view_count` は**増やさない** |
| FR-SW-13 | `GET /v1/shares` の items に `edit_count` / `last_edited_at` を追加する（オーナーが編集の有無を確認できる） |
| FR-SW-14 | 編集成功をアプリログに 1 行出す（`share_link_id` / `application_id` / 変更されたキー名）。**値（座席文字列など）はログに出さない**（`docs/08` の個人情報方針） |
| FR-SW-15 | read リンクに対する PATCH・失効/期限切れリンクへの PATCH で、DB は一切変更されない |

---

## 3. 非機能要件

| # | 要件 |
|---|---|
| NFR-1 | 既存の `*.spec.ts` は**書き換えずに Green のまま**であること。例外は「契約に追加キーが増えたことによる `toEqual` の更新」のみで、対象を plan に列挙する |
| NFR-2 | 新規依存は **`@nestjs/throttler`（Q7）と `resend`（Q1）の 2 つだけ**。パスワードハッシュ・JWT 検証・HMAC は `node:crypto` で完結させる（jest CJS 互換・Docker ビルド互換） |
| NFR-2a | `resend` は **T0 の完了ゲートで `npm test` が通ることを確認する**。ts-jest（CJS）で解決できない場合は依存を外し、`fetch('https://api.resend.com/emails')` 直叩きの `ResendMailSender` に切り替える（`jose` 撤退と同じ判断基準）。**どちらを採っても `MailSender` 抽象より上位のコードは変わらない** |
| NFR-3 | テストは DB・ネットワークに依存しない。Prisma / JWKS プロバイダ / 時刻はモックまたは fake timers |
| NFR-4 | ネットワーク検証（JWKS 取得）はタイムアウト付き。取得失敗時に検証を素通しさせない |
| NFR-5 | `src` が読む環境変数を増やしたら `docker-compose.yml` の `api.environment` と `apps/api/.env.example` を同時に更新する（F13） |
| NFR-6 | 秘密情報（パスワード平文・identity token・share token）を例外メッセージ・ログ・`details` に含めない |

---

## 4. 制約・設計判断（採用案と却下案）

### C1. Google 検証器は Apple の実装基盤を共有する（コピーしない）

**採用**: `src/auth/oidc/` に RS256 JWT 検証のピュア関数と JWKS プロバイダの基底クラスを切り出し、Apple / Google の verifier がそれを使う。**`AppleTokenVerifier` / `AppleJwksProvider` の DI トークン・クラス名・振る舞いは変えない**（既存 spec が無改変で通ることがリグレッションの検出手段）。

却下案 A: Google 用にコピーする — `alg` 摩り替え対策・timing safe 比較というセキュリティ上重要なコードが 2 箇所に分かれる。
却下案 B: `google-auth-library` / `jose` を入れる — F3 の経緯（jest CJS 非互換）と重複。ネットワーク呼び出しの単体テストも難しくなる。

### C2. パスワード認証の識別子に `users.email` を使わず新列 `email_normalized` を足す

**採用**: `users.email_normalized String? @unique` を新設。`users.email` は連絡先のまま（一意制約なし）。

却下案: `users.email` に `@unique` を付ける — Google/Apple が返した email と、メール登録した email が衝突すると**既存の OAuth サインインが P2002 で落ちる**。認証の同一性キーと連絡先を混ぜてはいけない。

### C3. 公開 write の対象行は `item_key`（リンク単位の HMAC）で指定する

**採用**: FR-SW-6。`public-share.presenter.ts` の不変条件「内部 UUID を一切含めない」（F8）を壊さない。リンクを失効させれば handle も無意味になる。

却下案 A: ペイロードに `application_id`（実 UUID）を載せる — 明文の不変条件に反し、レビューで確実に指摘される（BE-4）。共有ページの JSON は URL を知る全員に見える。
却下案 B: `event_name` + `round_name` + `rep_name` で行を特定する — 同名行が作れるため一意にならない。

### C4. 楽観ロック（`rev`）を入れる

**採用**: 共同編集は「同じ行を 2 人が同時に触る」ことが前提の機能。`updateMany({ where: { id, updatedAt: expected } })` で count 0 → `CONFLICT` 409 とする。実装コストは 1 フィールド + 1 条件。

却下案 A: 後勝ち（ロック無し）— 更新の消失が黙って起きる。共同編集としては不合格。
却下案 B: `updated_at` を素で公開して `If-Match` にする — オーナーが「いつ編集したか」というメタ情報を共有先に渡す。不透明な `rev` で足りる。

### C5. 公開 write エンドポイントは「共有先（未認証 Web）」専用。iOS のオーナー側は使わない

オーナーは自分の申込を **`PATCH /v1/applications/:id`（Bearer）** で更新できる。`ApplicationListView` の共有ボードでオーナーが行う編集は認証 API を使う。
公開 write は「トークンを受け取った相手（アプリを持っていない人）」のための経路。

**帰結（iOS 計画への申し送り）**: 生トークンは発行時 1 回しか返らない（既存契約）。オーナーが後から自分の共有ボードを公開 API 経由で操作する必要は無いので、**この制約は Phase 2 でも据え置きでよい**。

### C6. `shared_with_account_ids` は Phase 2 でも ACL にしない

`docs/10` §3 は「Phase 2 で ACL にするか再決定」としている。本計画では **URL を知っていれば編集可**（モックどおり）を採る。

却下案: 共有先にアカウントを要求し `shared_with_account_ids` と照合する — 「相手はアプリユーザーではない」という前提（`docs/07:346`）と矛盾する。アカウント必須の共同編集は `boards` / `board_members` を持つ Phase 2 本体（`docs/09:128`）の仕事。

**したがって write リンクの URL は「編集できる URL」である**。これは仕様であり、iOS / Web の発行 UI で明示する必要がある（`ShareRecipientsView` の文言 — iOS 側の申し送り）。

### C7. エラーコードの追加は最小限にし、1 タスク（T0）でまとめて行う

追加: `AUTH_GOOGLE_INVALID`(401) / `AUTH_CREDENTIALS_INVALID`(401) / `AUTH_RESET_CODE_INVALID`(401) / `EMAIL_ALREADY_REGISTERED`(409) / `PLAN_LIMIT_SHARE_WRITE`(403) / `RATE_LIMITED`(429) の **6 つ**。
read リンクへの write 拒否・公演数超過行への write 拒否は**既存の `FORBIDDEN` を再利用**する（read リンクは GET で 200 を返すため、403 で「リンクは存在する」ことが漏れても新しい情報にならない。一方で 403 の理由は区別しない — FR-SW-9a）。

### C8. write 共有の課金差は「発行可否」ではなく「公演数」で付ける（Q3・上限値 3 の根拠）

**採用**: Free / Plus とも `permission:"write"` を発行できる。Free は **1 本の write 共有に含められる公演数を 3 件**までとする。

**上限を 3 件にした理由**:

| 観点 | 説明 |
|---|---|
| 既存の粒度と揃う | Free の制限は「名義 3 件」「有効な共有リンク 1 本」。3 という数字はユーザーが既に学習している粒度 |
| Free の想定利用に足りる | 「家族・友人と数公演を一緒に管理する」（`docs/07:823` のファミリー利用）は 1〜3 公演で収まることが多い |
| ペイウォールとして機能する | 実際のアリーナツアーは 5〜20 公演。ツアー全体を共同管理したい人は Plus に上がる動機を持つ（`docs/07` 6.2 の補助トリガー「共有リンク数」と地続き） |

**却下案**:

- **5 件** — 実ツアーの半分程度をカバーでき Free の満足度は上がるが、`docs/07` の Free 制限の粒度から外れ、Plus への動機が弱まる
- **1 件** — 実質使えない。write 共有を作った意味が無くなる
- **当初案（Free は発行不可）** — `docs/07:95` には忠実だが、iOS のペイウォールが未実装（`docs/plans/ios-network-integration/` Q2）の現状では **Free ユーザーが機能に一切触れられない**。「触れるが規模で頭打ち」のほうが価値を体験してから課金判断できる

**値の変更容易性**: 上限は `EntitlementsService` の定数 1 箇所（`FREE_SHARE_WRITE_EVENT_LIMIT`）。運用データを見て変えられる。

**`docs/07-monetization.md` への追記案（T3 で反映）**:

> | 13b | 共有リンクの共同編集（write） | Phase 1 | △ 1 本あたり公演 **3 件**まで | ○ 無制限 | 本格的な共同編集ボード（21）とは別物の軽量版 |
>
> 21（共同編集ボード / `boards`・`board_members`・3 段階権限）は Phase 2 の Plus 限定機能として据え置く。

### C9. リセットは「メール内リンク」ではなく「8 桁コード」で受け渡す（Q1）

**採用**: `reset-request` でコードをメール送信し、アプリでコードと新パスワードを入力して `reset` を呼ぶ。

- 保存は `sha256(userId + ':' + code)`。**userId を混ぜる**ことで、DB が漏れても行をまたいだ逆引き表が使えない
- 8 桁 + TTL 15 分 + 試行 5 回 + email 単位のレート制限。総当たり成功確率は 15 分あたり 5/10^8

**却下案**: Web ページへのリンク（認証用 Web が無い）/ Universal Link（`apple-app-site-association` の配信基盤が未整備）。将来リンク方式を足すときも**同じテーブル行を使えるので後方互換**。

**採用しなかったが記録しておく設計**: `email_verified` 列。読む経路が無い列を作らない（`docs/03` の方針）。リセット成功が事実上の所有確認になるため、列を足す必要が出るのは「確認済みユーザーだけに何かを許す」機能を作るとき。

---

## 5. エッジケース（実装で必ず考慮する）

| # | ケース | 期待 |
|---|---|---|
| E-1 | 同一 `google_sub` の同時初回サインイン | P2002 を捕まえて既存行を読み直し、後発は `is_new:false`（F4 と同形） |
| E-2 | 同一 `email_normalized` の同時 register | P2002 → `EMAIL_ALREADY_REGISTERED` 409（500 にしない・BE-6） |
| E-3 | Google の `email_verified` が `false` / 欠落 | `users.email` に保存しない（null のまま） |
| E-4 | Apple ユーザーと同じメールで register | 別ユーザーとして成功する（Q2 の帰結）。`email_normalized` は Apple 行に無いため衝突しない |
| E-5 | `password` が Unicode（絵文字含む） | UTF-8 バイト長でなく**文字数**で 8〜128 を判定。scrypt には UTF-8 バイト列を渡す |
| E-6 | パスワード変更中に別端末が refresh | 変更 TX 内で全 refresh を失効。競合した refresh は `AUTH_REFRESH_INVALID` 401（既存挙動） |
| E-7 | write リンクの scope tour が**論理削除**された | `TourMatrixService.build` の NOT_FOUND を `SHARE_INVALID` 404 に写す（既存 `ResolveShareUseCase` と同じ） |
| E-8 | write リンク経由で更新しようとした application が削除済み | 行が matrix に出ないので `item_key` 不一致 → `SHARE_INVALID` 404 |
| E-9 | 同じ `rev` で 2 リクエストが同時到達 | 条件付き更新で片方だけ成功。もう片方は `CONFLICT` 409 |
| E-10 | write リンクだが tour に application が 0 件 | 200 + `items: []`（既存 E-10 と同じ） |
| E-11 | 全行が `history_visible=false` の tour を write 共有 | ペイロードは返るが全行 403。**オーナー側 UI で注意を出すべき**（iOS 申し送り） |
| E-12 | `status` と `seat` の両方を省略した PATCH | `VALIDATION_ERROR` 400（空更新で `edit_count` を増やさない） |
| E-13 | `seat` に空文字 | `null` ではなく空文字として保存（既存 `PATCH /v1/applications` と同挙動に揃える）。`null` を明示送信した場合は null |
| E-14 | 期限切れちょうど（`expires_at === now`） | 無効（既存 `isShareActive` の判定をそのまま使う） |
| E-15 | throttle 超過 | `RATE_LIMITED` 429 + 既存 envelope（`request_id` 付き） |
| E-16 | 未登録 email への `reset-request` | 202（メールは送らない。存在を漏らさない） |
| E-17 | Apple / Google だけのユーザーの email への `reset-request` | 202（メールは送らない。`email_normalized` が無いので検索にも掛からない） |
| E-18 | `reset-request` を連続で叩く | 直前の未使用コードは失効し、常に最新 1 本だけが有効 |
| E-19 | リセット中に別端末で `POST /v1/auth/password` | どちらも「全 refresh 失効 + 新ペア」なので後勝ち。先の端末は次の refresh で `AUTH_REFRESH_INVALID` 401 |
| E-20 | メール送信 API が失敗（Resend の障害・タイムアウト） | **202 は返す**（存在漏洩を避けるため応答を変えない）。失敗はサーバーログにエラーとして残す。コードは発行済みなのでユーザーは再要求できる |
| E-21 | write 共有発行後に公演が 3 件 → 10 件に増えた（Free） | リンクは有効。先頭 3 公演の行のみ `editable:true`、残り 7 公演は閲覧のみ・PATCH は 403 |
| E-22 | Plus で 10 公演の write 共有を発行 → Free にダウングレード | 同上（閲覧時点の上限で自動的に絞られる）。リンクを失効させたりはしない |
| E-23 | write 共有の対象 tour の公演が 0 件 | 発行できる（0 ≤ 3）。ペイロードは `items: []` |
| E-24 | 公演数の数え方 | `events` の `deleted_at is null` の件数。**application の有無は問わない**（申込ゼロの公演も 1 件として数える） |

---

## 6. 影響範囲

### DB（`apps/api/prisma/schema.prisma`）

```
User
  + passwordHash      String?   @map("password_hash")
  + emailNormalized   String?   @unique @map("email_normalized")
  + passwordUpdatedAt DateTime? @map("password_updated_at") @db.Timestamptz(6)
  + passwordResetCodes PasswordResetCode[]

ShareLink
  + editCount    Int       @default(0) @map("edit_count")
  + lastEditedAt DateTime? @map("last_edited_at") @db.Timestamptz(6)

// 新規（refresh_tokens と同じ形 — F17）
PasswordResetCode
  id           String    @id @db.Uuid
  userId       String    @map("user_id") @db.Uuid
  codeHash     String    @unique @map("code_hash")   // sha256(userId + ':' + code)
  expiresAt    DateTime  @map("expires_at") @db.Timestamptz(6)
  usedAt       DateTime? @map("used_at") @db.Timestamptz(6)
  attemptCount Int       @default(0) @map("attempt_count")
  createdAt    DateTime  @default(now()) @map("created_at") @db.Timestamptz(6)
  @@index([userId], map: "password_reset_codes_user_idx")
  @@map("password_reset_codes")
```

`permission` 列は既存のため変更なし。`email_verified` 列は**足さない**（C9）。

### BE

| 層 | 追加・変更 |
|---|---|
| 共通 | `common/errors/error-codes.ts`（+6 コード・429 のマッピング）/ `common/throttling/`（tracker 別ガード）/ **`mail/`（`MailSender` 抽象 + `ResendMailSender` + `@Global` な `MailModule`）** / `app.module.ts`（ThrottlerModule・MailModule）/ `package.json` |
| auth | `oidc/`（RS256 検証・JWKS 基底の切り出し）/ `google-token.verifier.ts` / `google-jwks.provider.ts` / `password.hasher.ts` / **`reset-code.generator.ts`** / dto 5 本 / use-case 5 本 / controller 6 ルート / `auth.service.ts`（Google・メールの find-or-create、全 refresh 失効、**リセットコードの発行・照合**） |
| me | `me.service.ts` の `authProviders` 導出（FR-EP-11）+ その spec |
| entitlements | **`shareWriteEventLimit(userId)` を追加**（`identityLimit` / `shareLimit` と同形。Free=3 / Plus=null） |
| shares | `dto/create-share.dto.ts`（`permission`）/ `shares.service.ts`（`permission` を受ける・`recordEdit`）/ `shares.presenter.ts`（`edit_count` / `last_edited_at`）/ `create-share.use-case.ts`（**公演数上限の判定**） |
| public | `public.controller.ts`（PATCH 追加）/ `public-share.presenter.ts`（`permission` / `item_key` / `rev` / `editable`）/ `share-item-key.ts`（新規）/ `use-cases/update-share-item.use-case.ts`（新規）/ `use-cases/resolve-share.use-case.ts`（公演数上限の適用）/ `public.module.ts`（`ApplicationsModule` を import） |
| tours | `tour-matrix.service.ts`（内部行に `application_updated_at` を追加し、`stripInternal` で確実に落とす） |
| setup | `app.setup.ts` の `GLOBAL_PREFIX_EXCLUDE` に公開 write パスを追加 |

### iOS（本計画では実装しない・申し送り）

- `docs/plans/ios-network-integration/` の T1（認証）: Google / メールのボタンが叩く先が確定する
- 同 T4（共有）: write リンク発行と共有ボードの編集（**オーナー側は `PATCH /v1/applications/:id`** — C5）
- `contract-mapping.md` の更新は iOS 計画側の責務

### docs（実装後に更新）

- `docs/04-api.md` §3.1（auth）/ §3.7（shares）に本計画の契約を反映
- `docs/03-database.md` に新列 + `password_reset_codes` テーブル
- `docs/10-mock-delta-2026-07-31.md` §2（認証表: メール+パスワードを「任意（推奨度低）」から実装済みへ）/ §3（共有モデルの Phase 表）
- `docs/09-roadmap.md`: write 共有リンクの Phase 1 前倒し（Q9）
- `docs/07-monetization.md`: 機能比較表に「共有リンクの共同編集（write）: Free △ 公演 3 件まで / Plus ○」を追加（C8 の追記案）
- `docs/08-compliance-risk.md`: ①`:522` の「Sign in with Apple のみ」を「Apple + Google + メール（4.8 は Apple 併設で充足）」に更新 ②**委託先一覧（`:268` / `:450`）に Resend（メール送信）を追記** — 法務ドキュメントの更新自体は本計画スコープ外だが、**未実施のままストア提出しない**

---

## 7. 本計画のスコープ外（着手しない）

| 対象 | 理由 |
|---|---|
| メールアドレス確認（verification）フロー / メールアドレス変更 | Q1。リセットが事実上の所有確認として働くため、`email_verified` を読む機能ができるまで作らない |
| `docs/08-compliance-risk.md` への Resend 追記（法務文書の本文更新） | Q1 の残課題。**ストア提出前に必須**だが本計画（BE 実装）とは別作業 |
| アカウント統合・プロバイダのリンク解除 | Q2。メール確認が前提 |
| `boards` / `board_members` による本格的な共同編集 | `docs/09` Phase 2 本体（Q9） |
| 共有先の編集履歴の閲覧 API | `edit_count` / `last_edited_at` までに留める（読む画面が無い） |
| Redis / DB バックエンドのレート制限・アカウントロック | Q7。インスタンス跨ぎの制限は infra 側で |
| Next.js 共有 Web ビューの編集 UI | Web の実装は別（`docs/09` 1-7） |
| iOS 実装 | 別計画（`docs/plans/ios-network-integration/`） |
| 退会・アカウント削除 | 既存計画でも未実装。本計画で増やさない |
