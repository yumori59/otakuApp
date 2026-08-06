# plan — backend-auth-and-shares-extension

契約の正: **`docs/plans/backend-domain-modules/api-contract.md` + 本ディレクトリの `api-contract-delta.md`**。
要件・設計判断: `requirements.md`。回答済みの確認事項: `questions-requirements.md`。

**確定状況（2026-08-02）**: Q1〜Q8 回答済み。Q9（docs 追記）のみ `[Assumed]` のまま進行をユーザーが承認。
→ **本計画は着手可能。保留中の AC は無い。**

回答で当初案から変わった点:

1. **パスワードリセットをスコープに含める**（メール送信 = Resend / 8 桁コード方式）
2. **write 共有は Free でも発行できる**。課金差は「1 本あたりの公演数上限（Free 3 件 / Plus 無制限）」

---

## 1. タスク一覧と依存関係

| Task | 内容 | 依存 | 担当エージェント候補 |
|---|---|---|---|
| **T0** | 基盤（依存追加・schema・エラーコード・throttler・**mail モジュール**・env） | なし | `nest-developer`（model: sonnet） |
| **T1** | auth: Google + Email/Password + **パスワードリセット** + `me.auth_providers` | T0 | `nest-developer`（**model: opus** — 認証・複数モジュール新規、rule 02 のエスカレーション条件） |
| **T2** | shares/public: 共有リンク Phase 2（write + 公演数上限） | T0 | `nest-developer`（**model: opus** — 未認証書き込み・前例なし設計） |
| **T3** | docs 反映（03 / 04 / 07 / 08 / 09 / 10） | T1・T2・R 完了後 | オーケストレーター（または `nest-developer` sonnet） |
| **R** | レビュー | T1・T2 完了後 | `code-reviewer`（**別セッション** / model: opus） |

```
T0 ──┬── T1 ──┐
     └── T2 ──┴── R ── T3
```

## 2. 並列実行可能なタスク

- **Wave 0（単独・直列必須）**: T0。`schema.prisma` / `app.module.ts` / `package.json` / `error-codes.ts` という「集中しやすいファイル」（rule 03）を 1 エージェントがまとめて触る
- **Wave 1（1 メッセージで 2 エージェント並列発行）**: **T1 と T2**。触るファイルが重複しない（下表）
- **Wave 2**: R（レビュー・集約）
- **Wave 3**: T3（docs）

### 同時に触らせないファイル（rule 03）

| ファイル | 所有タスク |
|---|---|
| `apps/api/package.json` / `prisma/schema.prisma` / `src/app.module.ts` / `src/common/errors/error-codes.ts` / `src/common/throttling/**` / `src/mail/**` / `docker-compose.yml` / `apps/api/.env.example` | **T0 のみ** |
| `src/auth/**` / `src/me/me.service.ts`(+spec) | **T1 のみ** |
| `src/shares/**` / `src/public/**` / `src/entitlements/**` / `src/tours/tour-matrix.service.ts`(+spec) / `src/app.setup.ts`(+spec) | **T2 のみ** |
| `src/applications/**` | **誰も変更しない**（T2 は `ApplicationsService` を再利用するだけ。`ApplicationsModule` は既に export 済み） |

T0 完了後に `cd apps/api && npx prisma generate` を通し、T1 / T2 は生成済み Prisma Client を前提に着手する。

---

## 3. T0: 基盤（詳細）

### 3.1 依存追加（`apps/api/package.json`）

```
@nestjs/throttler   (Nest 11 対応版)
resend              (Q1 — 下記の互換確認が完了条件)
```

**これ以外の依存を足さない。** パスワードハッシュ・JWT 検証・HMAC は `node:crypto`。

**`resend` の互換確認（T0 の完了条件に含める）**:

1. `resend` を追加した状態で `cd apps/api && npm test` と `npx tsc --noEmit` が通ること
2. **通らない場合（ESM 専用等で ts-jest が解決できない場合）は `resend` を `package.json` から外し、`ResendMailSender` を `fetch('https://api.resend.com/emails', { method:'POST', headers:{ Authorization:'Bearer ' + apiKey } })` の直叩き実装に切り替える**（`jose` を撤退したときと同じ判断基準 / `requirements.md` F3）
3. どちらを採っても `MailSender` 抽象より上位のコードは変わらない。**採用したほうを完了報告に明記する**

### 3.2 `prisma/schema.prisma`（**T0 のみが編集**）

```prisma
model User {
  // 既存に追加
  passwordHash       String?   @map("password_hash")
  emailNormalized    String?   @unique @map("email_normalized")
  passwordUpdatedAt  DateTime? @map("password_updated_at") @db.Timestamptz(6)
  passwordResetCodes PasswordResetCode[]
}

model ShareLink {
  // 既存に追加
  editCount    Int       @default(0) @map("edit_count")
  lastEditedAt DateTime? @map("last_edited_at") @db.Timestamptz(6)
}

// 新規。refresh_tokens と同じ形（生値は DB に入れない）
model PasswordResetCode {
  id           String    @id @db.Uuid
  userId       String    @map("user_id") @db.Uuid
  codeHash     String    @unique @map("code_hash")
  expiresAt    DateTime  @map("expires_at") @db.Timestamptz(6)
  usedAt       DateTime? @map("used_at") @db.Timestamptz(6)
  attemptCount Int       @default(0) @map("attempt_count")
  createdAt    DateTime  @default(now()) @map("created_at") @db.Timestamptz(6)

  user User @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@index([userId], map: "password_reset_codes_user_idx")
  @@map("password_reset_codes")
}
```

- `ShareLink.permission` は**既存列**。変更しない
- `email_verified` 列は作らない（`requirements.md` C9）
- 反映は `cd apps/api && npx prisma db push`（**必ず `apps/api/` で実行** — BE-5）

### 3.3 `src/common/errors/error-codes.ts`

`ErrorCode` に 6 つ追加し、`ERROR_CODE_STATUS` に対応を追加する。

```
AUTH_GOOGLE_INVALID       -> 401
AUTH_CREDENTIALS_INVALID  -> 401
AUTH_RESET_CODE_INVALID   -> 401
EMAIL_ALREADY_REGISTERED  -> 409
PLAN_LIMIT_SHARE_WRITE    -> 403
RATE_LIMITED              -> 429
```

`errorCodeFromStatus` に `case HttpStatus.TOO_MANY_REQUESTS: return ErrorCode.RATE_LIMITED;` を追加（`ThrottlerException` は HttpException 429 として `AllExceptionsFilter` に届く）。

### 3.4 throttler の配線（`src/common/throttling/`）

- `app.module.ts` には `ThrottlerModule.forRoot([...])` を import する**だけ**。`APP_GUARD` としてのグローバル登録は**しない**（全ルートに副作用を出さない）
- tracker 別のガードを用意し、適用は T1 / T2 が各コントローラで行う:
  - `EmailThrottlerGuard` — body の `email` を `trim().toLowerCase()`
  - `UserThrottlerGuard` — `req.user.id`
  - `TokenThrottlerGuard` — `req.params.token`
- 名前付き throttler を定義する（`api-contract-delta.md` §0 の表と一致させる）: `auth-email`（10 回/5 分）/ `auth-user`（10 回/5 分）/ `reset-request`（3 回/15 分）/ `reset-submit`（10 回/15 分）/ `share-write`（60 回/分）
- **IP を tracker にしない**（`questions-requirements.md` Q7）
- 閾値は**コード定数**（env を増やさない）

### 3.5 `src/mail/`（新規・`@Global`）

| ファイル | 内容 |
|---|---|
| `mail.module.ts` | `@Global()`。`{ provide: MailSender, useClass: ResendMailSender }` |
| `mail.sender.ts` | `abstract class MailSender { abstract send(input: { to: string; subject: string; text: string }): Promise<void> }`（**DI トークン兼インターフェース**。`AppleTokenVerifier` と同じ形 — spec はこれをスタブに差し替える） |
| `resend.mail.sender.ts` | `RESEND_API_KEY` / `RESEND_FROM_EMAIL` を `ConfigService` から読む。**本番で未設定なら送信時に `AppError(INTERNAL)`**。非本番かつ未設定のときのみ `Logger` に本文を出力（ローカル開発用） |

**メール本文のテンプレートは T1 が持つ**（`MailSender` は「送る」だけ。件名・本文の組み立ては auth のドメイン）。

### 3.6 env（`docker-compose.yml` の `api.environment` + `apps/api/.env.example`）

```
GOOGLE_CLIENT_IDS: changeme.apps.googleusercontent.com
GOOGLE_ISSUER: https://accounts.google.com
GOOGLE_JWKS_URL: https://www.googleapis.com/oauth2/v3/certs
RESEND_API_KEY: ""
RESEND_FROM_EMAIL: no-reply@example.com
```

`config/env-coverage.spec.ts` は「src が読む env == compose の env」を厳密に照合する（過不足どちらも失敗）。

---

## 4. T1: auth（詳細）

**内部の実装順**: ① OIDC 共通化 + Google → ② Email/Password → ③ リセット。①で既存 Apple の spec が Green のままであることを確認してから先へ進む。

### 4.1 共通化（既存 Apple 実装のリファクタ）

`src/auth/oidc/` を新設。**`AppleTokenVerifier` / `AppleJwksProvider` / `AppleIdentityTokenVerifier` / `RemoteAppleJwksProvider` のクラス名・DI トークン・振る舞いは変更しない。**

| 新ファイル | 内容 |
|---|---|
| `oidc/jwt-rs256.ts` | `decodeSegment` / `verifyRs256` / `audienceMatches` / `safeEquals` / ヘッダ検証（`alg !== RS256` を拒否）のピュア関数 |
| `oidc/remote-jwks.provider.ts` | `JwksProvider` 抽象 + `RemoteJwksProvider`（URL・TTL 1h・`FORCED_FETCH_COOLDOWN_MS` 30s・inflight 共有・失敗時は旧キャッシュ）基底クラス |

**`apple-*.spec.ts` は 1 行も変更せずに Green のままであること**（リファクタのリグレッション検出手段 / NFR-1）。

### 4.2 Google

| ファイル | 内容 |
|---|---|
| `google-jwks.provider.ts` | `GoogleJwksProvider`（`RemoteJwksProvider` を継承・`GOOGLE_JWKS_URL`） |
| `google-token.verifier.ts` | `GoogleTokenVerifier` 抽象 + `GoogleIdentityTokenVerifier`。`iss` は `GOOGLE_ISSUER` 未設定時に `https://accounts.google.com` / `accounts.google.com` の両方を受理。`aud` は `GOOGLE_CLIENT_IDS` の分割リストのいずれか。失敗は全部 `AUTH_GOOGLE_INVALID` |
| `dto/google-sign-in.dto.ts` | `id_token`（必須・string）/ `nonce`（任意） |
| `use-cases/sign-in-with-google.use-case.ts` | verify → `AuthService.findOrCreateGoogleUser` → token 発行 |
| `auth.service.ts` | `findOrCreateGoogleUser(claims)` を `findOrCreateAppleUser` と同形で追加（P2002 リカバリ含む） |

### 4.3 Email + Password

| ファイル | 内容 |
|---|---|
| `password.hasher.ts` | `hash` / `verify` / `needsRehash`。形式 `scrypt$N=32768,r=8,p=3$<salt>$<hash>`、`timingSafeEqual` 比較、`maxmem` 明示 |
| `dto/register.dto.ts` | `email`（`@IsEmail()` / `@MaxLength(255)`）/ `password`（8〜128） |
| `dto/login.dto.ts` | `email` + `password`。**password の長さ下限は掛けない**（旧ポリシーのユーザーを弾かない）。`@IsString()` + `@MaxLength(1024)` |
| `dto/change-password.dto.ts` | `current_password` / `new_password`（8〜128・同値なら 400） |
| `use-cases/register-with-email.use-case.ts` | 正規化 → ハッシュ → `AuthService.createEmailUser`（users + profiles + entitlements 1 TX・`AccountIdGenerator.issue` 経由）→ token 発行 |
| `use-cases/login-with-email.use-case.ts` | 正規化 → 取得 → **ユーザー不在時もダミーハッシュで verify を実行** → 一致で token 発行 + 必要なら再ハッシュ |
| `use-cases/change-password.use-case.ts` | current 検証 → 新ハッシュ保存 + **refresh 全件失効** + 新ペア発行（1 TX） |
| `auth.service.ts` | `findByEmailNormalized` / `createEmailUser` / `updatePasswordHash` / `revokeAllRefreshTokens(userId, tx)` |
| `auth.types.ts` | `AppleSignInResponse` を `SignInResponse` にリネーム（4 経路共通）。参照元は auth/ 内のみ |

### 4.4 パスワードリセット

| ファイル | 内容 |
|---|---|
| `reset-code.generator.ts` | `randomInt` ベースで **8 桁数字**（先頭 0 を許す）。`codeHash(userId, code) = sha256Hex(userId + ':' + code)` |
| `dto/reset-request.dto.ts` | `email` のみ |
| `dto/reset-password.dto.ts` | `email` / `code`（`@Matches(/^\d{8}$/)`）/ `new_password`（8〜128） |
| `use-cases/request-password-reset.use-case.ts` | 対象ユーザー（`email_normalized` 一致 **かつ** `password_hash` 非 null）を引く → 既存未使用コードを失効 → 新コード発行 → `MailSender.send` → **常に 202**。送信失敗は握ってログに残す（応答を変えない） |
| `use-cases/reset-password.use-case.ts` | email → user → 有効コード行 → ハッシュ照合。失敗なら `attempt_count += 1`（5 で失効）+ `AUTH_RESET_CODE_INVALID`。成功なら 1 TX で「パスワード更新 + コード使用済み + 他コード失効 + refresh 全件失効」→ 新ペア発行 |
| `auth.service.ts` | `issueResetCode` / `findActiveResetCode` / `recordResetAttempt` / `consumeResetCode` |
| `reset-mail.ts` | 件名「【参戦名義帳】パスワード再設定のご案内」/ 本文にコード・有効期限 15 分・心当たりが無ければ無視してよい旨。**他の個人情報を載せない** |

**TTL・試行回数はコード定数**（`RESET_CODE_TTL_MINUTES = 15` / `RESET_CODE_MAX_ATTEMPTS = 5`）。

### 4.5 controller

`auth.controller.ts` に 6 ルートを足す（既存 3 + 新規 6 = 9）。

| ルート | `@Public()` | throttler |
|---|---|---|
| `POST google` | ○ | 無し |
| `POST register` | ○（201） | `auth-email` |
| `POST login` | ○ | `auth-email` |
| `POST password` | **付けない**（Bearer 必須） | `auth-user` |
| `POST password/reset-request` | ○（202） | `reset-request` |
| `POST password/reset` | ○ | `reset-submit` |

**`POST password` に `@Public()` を付けないこと**（BE-4）。`password` と `password/reset*` のルート定義が衝突しないことを確認する。

### 4.6 me（FR-EP-11）

`me/me.service.ts` の `authProviders()` を `password_hash` ベースに変更。`UserWithProfile` 型に `passwordHash` を追加する（`include: { profile: true }` は全列取得なのでクエリ変更は不要）。`me.service.spec.ts` に AC-EP-14 を追加。

---

## 5. T2: shares / public（詳細）

### 5.1 entitlements

`entitlements/entitlements.service.ts` に `shareWriteEventLimit(userId): Promise<number | null>` を追加（`identityLimit` / `shareLimit` と同形）。定数 `FREE_SHARE_WRITE_EVENT_LIMIT = 3`、Plus は `null`。

### 5.2 発行側

| ファイル | 内容 |
|---|---|
| `shares/dto/create-share.dto.ts` | `SHARE_PERMISSIONS = ['read','write']`。`permission?`（`@IsOptional() @IsIn(...)`）。`write` × `identity_summary` を弾くカスタム制約 |
| `shares/shares.service.ts` | `create()` の `permission:'read'` ハードコードを入力値（既定 `read`）に変更。`recordEdit(id, at)` を追加。**対象 tour の未削除 event 数を数えるメソッド**を追加（Prisma アクセスは Service 層 — BE-3） |
| `shares/shares.presenter.ts` | `ShareListItemResponse` に `edit_count` / `last_edited_at` |
| `shares/use-cases/create-share.use-case.ts` | `permission==='write'` のとき `shareWriteEventLimit` と event 数を比較 → 超過で `PLAN_LIMIT_SHARE_WRITE` 403（`details:{limit,current}`）。既存の `PLAN_LIMIT_SHARE`（本数上限）判定より**後**に置く |

### 5.3 handle（新規・`public/share-item-key.ts`）

```
itemKey(tokenHash, applicationId)            = base64url(hmacSha256(tokenHash, `item:${applicationId}`)).slice(0, 22)
itemRev(tokenHash, applicationId, updatedAt) = base64url(hmacSha256(tokenHash, `rev:${applicationId}:${updatedAt.toISOString()}`)).slice(0, 16)
```

- `createHmac('sha256', tokenHash)`。key はクライアントに出ない高エントロピー値なので**新しい env（秘密鍵）を増やさない**
- 照合は `timingSafeEqual`（長さ不一致は false・例外にしない）

### 5.4 tour matrix

`TourMatrixInternalRow` に `application_updated_at: Date` を追加し、**`stripInternal` で必ず落とす**。
`GET /v1/tours/:id/matrix` のレスポンスキーは 1 つも変わってはいけない（AC-SW-25）。

### 5.5 公開側

| ファイル | 内容 |
|---|---|
| `public/public-share.presenter.ts` | ペイロードに `permission`。`write` のときだけ item に `item_key` / `rev` / `editable`。`editable = history_visible && その公演が先頭 N 件以内`。公演順は matrix の行順から distinct `event_id` を取り出した順。**マスキングの不変条件（内部 UUID を出さない）は維持** |
| `public/use-cases/resolve-share.use-case.ts` | presenter へ `link.permission` / `link.tokenHash` / `shareWriteEventLimit(link.ownerId)` を渡す |
| `public/use-cases/update-share-item.use-case.ts`（新規） | `api-contract-delta.md` §4 の判定順序をそのまま実装。更新は `ApplicationsService.transaction` の中で `assertOwned(link.ownerId, applicationId, tx)` → **条件付き更新で `rev` を守る** → `applyUpdate(link.ownerId, id, { status?, seat_raw? }, tx)`。成功後に `SharesService.recordEdit` とログ 1 行（変更キー名のみ・値は出さない） |
| `public/public.controller.ts` | `PATCH :token/items/:item_key` を追加。`@Public()` + `X-Robots-Tag` + `TokenThrottlerGuard` |
| `public/public.module.ts` | `ApplicationsModule` を imports に追加 |
| `public/dto/update-share-item.dto.ts`（新規） | `rev`（必須）/ `status`（`@IsIn(APPLICATION_STATUSES)`）/ `seat`（`@MaxLength(200)`・null 可）。両方欠落で 400 |
| `app.setup.ts` | `GLOBAL_PREFIX_EXCLUDE` に `'public/shares/:token/items/:item_key'` を追加（`app.setup.spec.ts` も更新） |

**楽観ロックの実装**: `tx.application.updateMany({ where: { id, ownerId, updatedAt: expectedUpdatedAt }, data })` の `count === 0` を CONFLICT にする（期待 `updated_at` は matrix 行から取得済み）。`rev` 文字列の一致確認と併せて 2 段で守る。

### 5.6 更新が必要な既存 spec（NFR-1 の例外・**これ以外は変更禁止**）

| ファイル | 理由 |
|---|---|
| `public/public.controller.spec.ts` / `public/use-cases/resolve-share.use-case.spec.ts` | ペイロードに `permission` キーが増える（E7） |
| `shares/shares.presenter.spec.ts` / `shares.controller.spec.ts` / `shares.service.spec.ts` | items に `edit_count` / `last_edited_at` が増える（E6） |
| `tours/tour-matrix.service.spec.ts` | 内部行に `application_updated_at` が増える（外部レスポンスは不変） |
| `entitlements/entitlements.service.spec.ts` | メソッド追加 |
| `app.setup.spec.ts` | exclude リストが増える |

---

## 6. 受入基準 → テストケース

**テスト先行（Red → Green）**。各 AC は 1 つ以上の `*.spec.ts` に対応させる。テストは DB / ネットワーク / メール送信に依存しない（Prisma・JWKS プロバイダ・`MailSender` をモック、時刻は fake timers）。

### T0（基盤）

| AC | 内容 |
|---|---|
| AC-T0-01 | 追加した 6 コードが `ERROR_CODE_STATUS` に 401/401/401/409/403/429 で載っている |
| AC-T0-02 | `errorCodeFromStatus(429) === 'RATE_LIMITED'` |
| AC-T0-03 | 429 の `HttpException` が `RATE_LIMITED` envelope（`request_id` 付き）で返る（`all-exceptions.filter.spec.ts` に 1 ケース） |
| AC-T0-04 | `src` が読む env が compose と一致（`GOOGLE_*` / `RESEND_*` 追加後も `env-coverage.spec.ts` が Green） |
| AC-T0-05 | `EmailThrottlerGuard.getTracker` が body の email を `trim().toLowerCase()` して返す。`UserThrottlerGuard` は `req.user.id`、`TokenThrottlerGuard` は `req.params.token` |
| AC-T0-06 | `ResendMailSender`: 本番（`NODE_ENV=production`）で `RESEND_API_KEY` 未設定 → 送信時に `INTERNAL` 500。**本文をログに出さない** |
| AC-T0-07 | `MailSender` をスタブに差し替えられる（DI トークンが抽象クラス）。テスト実行中に外部 HTTP が発生しない |
| AC-T0-08 | `npm test` / `npx tsc --noEmit` が Green（**`resend` の CJS 互換確認。落ちたら fetch 実装に切り替え、報告に明記**） |

### T1a（Google）

| AC | 内容 |
|---|---|
| AC-GA-01 | 有効な id_token（RS256 / `iss=https://accounts.google.com` / `aud ∈ GOOGLE_CLIENT_IDS` / `exp` 未来）→ 200・`is_new:true`・`google_sub` 行が作られる |
| AC-GA-02 | 同じ sub で 2 回目 → 同じ user id・`is_new:false`・行が増えない |
| AC-GA-03 | `alg` が RS256 以外（`none` / `HS256`）→ `AUTH_GOOGLE_INVALID` 401 |
| AC-GA-04 | `aud` がリストに無い → 401 |
| AC-GA-05 | `iss` が `accounts.google.com`（スキーマ無し）でも成功。`GOOGLE_ISSUER` 設定時は不一致で 401 |
| AC-GA-06 | `exp` が過去 → 401 |
| AC-GA-07 | req が `nonce` を送り payload と不一致 → 401 / 一致 → 200 / req が送らなければ payload の nonce は無視 |
| AC-GA-08 | 未知 kid → 401（強制再取得は 30 秒 cooldown） |
| AC-GA-09 | `email_verified` が false / 欠落 → `users.email` に保存しない |
| AC-GA-10 | `GOOGLE_CLIENT_IDS` 未設定 → `INTERNAL` 500 |
| AC-GA-11 | **既存の `apple-token.verifier.spec.ts` / `apple-jwks.provider.spec.ts` が無改変で Green** |
| AC-GA-12 | 初回同時サインインの P2002 → 読み直して `is_new:false`（500 にしない・BE-6） |
| AC-GA-13 | レスポンスの JSON キーが `POST /v1/auth/apple` と完全一致 |

### T1b（Email + Password）

| AC | 内容 |
|---|---|
| AC-EP-01 | register 成功 → **201** + トークンペア + `is_new:true`。profiles(`account_id`) と entitlements(`free`) が同時に作られる |
| AC-EP-02 | `password_hash` が `scrypt$N=32768,r=8,p=3$...` 形式。**平文が保存・ログ・レスポンスに現れない** |
| AC-EP-03 | `"Fan@Example.com "` → `email_normalized` は `fan@example.com`、`email` は入力どおり |
| AC-EP-04 | 同じ正規化 email で再 register（大小・空白違い含む）→ `EMAIL_ALREADY_REGISTERED` 409 |
| AC-EP-05 | 同時 register の P2002 → 500 ではなく 409（BE-6） |
| AC-EP-06 | password 7 / 129 文字 → 400。email 形式不正 → 400 |
| AC-EP-07 | login 成功 → 200 + `is_new:false` |
| AC-EP-08 | 未登録 email / パスワード誤り / `password_hash` が null → **同一の** `AUTH_CREDENTIALS_INVALID` 401（code も message も同一） |
| AC-EP-09 | ユーザー不在時もハッシュ照合が 1 回実行される（hasher のモック呼び出し回数で検証） |
| AC-EP-10 | login 成功時、保存パラメータが現行既定と異なれば再ハッシュして保存 |
| AC-EP-11 | `POST /v1/auth/password`: 正しい current → 200 + 新ペア。**その user の既存 refresh が全件 `revoked_at` を持つ** |
| AC-EP-12 | current 不一致 → 401。`password_hash` が null → `FORBIDDEN` 403。`current === new` → 400 |
| AC-EP-13 | `POST /v1/auth/password` に Bearer 無し → `UNAUTHENTICATED` 401（`@Public()` を付けていないこと・BE-4） |
| AC-EP-14 | `auth_providers`: password のみ → `["email"]` / apple+password → `["apple","email"]` / apple のみ + `email` 列あり → `["apple"]` |
| AC-EP-15 | login を同一 email で上限超過 → `RATE_LIMITED` 429 |

### T1c（パスワードリセット）

| AC | 内容 |
|---|---|
| AC-PR-01 | `reset-request`: 登録済み / 未登録 / Apple のみのユーザーの email — **いずれも 202 + 空ボディ**（応答が同一） |
| AC-PR-02 | `MailSender.send` が呼ばれるのは「`email_normalized` 一致 **かつ** `password_hash` 非 null」のときだけ |
| AC-PR-03 | 発行時に同一ユーザーの未使用コードが失効し、有効なのは最新 1 本だけ |
| AC-PR-04 | コードは 8 桁数字。DB には `sha256(userId + ':' + code)` のみ。**平文コードが DB・レスポンス・ログに現れない** |
| AC-PR-05 | メール本文にコード・有効期限が含まれ、会員番号 / 名義名など他の個人情報を含まない |
| AC-PR-06 | `MailSender.send` が例外を投げても **202** を返す。エラーはログに残る |
| AC-PR-07 | `reset` 成功 → 200 + トークンペア + `is_new:false`。`password_hash` / `password_updated_at` 更新 |
| AC-PR-08 | `reset` 成功で ①当該コードが `used_at` ②他の未使用コードも失効 ③**その user の refresh が全件失効**（すべて同一 TX） |
| AC-PR-09 | 未知 email / 誤コード / 期限切れ（15 分ちょうどを含む）/ 使用済み → **すべて同一の** `AUTH_RESET_CODE_INVALID` 401 |
| AC-PR-10 | 誤コード 5 回でそのコードが失効し、6 回目は正しいコードでも 401 |
| AC-PR-11 | `new_password` の制約は register と同一（8〜128）。`code` が 8 桁数字でなければ 400 |
| AC-PR-12 | `reset-request` / `reset` を上限超過 → `RATE_LIMITED` 429 |
| AC-PR-13 | リセット後に旧パスワードで login → 401、新パスワードで login → 200 |

### T2（共有 write）

| AC | 内容 |
|---|---|
| AC-SW-01 | `POST /v1/shares` で `permission` 省略 → `read`（**既存 spec が無改変で Green**） |
| AC-SW-02 | `permission:"write"` + `scope_type:"tour"` → 201・レスポンスと DB が `write` |
| AC-SW-03 | `permission:"write"` + `identity_summary` → 400 |
| AC-SW-04 | 未知 permission（`"admin"` / `"READ"`）→ 400（黙って `read` に落とさない・BE-2） |
| AC-SW-05 | **Free** で未削除 event 4 件の tour に write 発行 → `PLAN_LIMIT_SHARE_WRITE` 403 + `details:{limit:3,current:4}`。3 件ちょうどは 201。0 件も 201 |
| AC-SW-05b | **Plus** は event 10 件でも 201（`shareWriteEventLimit` が null） |
| AC-SW-05c | `permission` 省略（read）なら event 10 件でも 201（read は制限を受けない） |
| AC-SW-05d | 論理削除済み event は数えない。申込ゼロの event は数える |
| AC-SW-06 | read リンクの GET は `permission:"read"` を含み、item に `item_key` / `rev` / `editable` を**含まない** |
| AC-SW-07 | write リンクの item は `item_key` / `rev` / `editable` を含む |
| AC-SW-08 | 同じ application でもリンクが違えば `item_key` が異なる |
| AC-SW-09 | `item_key` / `rev` から application UUID・`updated_at` が復元できない（生成関数の単体テスト） |
| AC-SW-10 | **Free** の write リンクで公演 5 件のツアーを GET → 先頭 3 公演の行は `editable:true`、残り 2 公演は `editable:false`（**全行は返る**） |
| AC-SW-10b | 同じリンクでもオーナーが Plus なら全行 `editable:true`（発行時ではなく閲覧時に判定） |
| AC-SW-11 | PATCH 成功（`status:"won"`）→ 200・DB 更新・レスポンスの `rev` が変化 |
| AC-SW-12 | PATCH 成功（`seat:"1F A列 12番"`）→ `seat_raw` 更新。`seat:null` → null。`seat:""` → 空文字 |
| AC-SW-13 | read リンクへの PATCH → `FORBIDDEN` 403・**DB 不変** |
| AC-SW-14 | 未知 / 失効 / 期限切れ（`expires_at === now` 含む）トークン → `SHARE_INVALID` 404・DB 不変 |
| AC-SW-15 | 他リンクの `item_key` / でたらめな `item_key` → `SHARE_INVALID` 404（403 と区別しない） |
| AC-SW-16 | `history_visible=false` の行 → `FORBIDDEN` 403・DB 不変 |
| AC-SW-17 | **公演数上限を超えた公演の行** → `FORBIDDEN` 403・DB 不変。**エラー本文から理由（プラン超過）が判別できない**（`PLAN_LIMIT_SHARE_WRITE` を返さない） |
| AC-SW-18 | `rev` 不一致 → `CONFLICT` 409 + `details.current` に `{status, seat, rev}`・DB 不変 |
| AC-SW-19 | `status` 未知値 → 400。`status` も `seat` も無い → 400。`round_name` / `note` / `ticket_count` を送る → 400 |
| AC-SW-20 | 成功時のみ `edit_count += 1` / `last_edited_at` 更新。403 / 404 / 409 では増えない |
| AC-SW-21 | PATCH は `view_count` を増やさない |
| AC-SW-22 | PATCH レスポンスに `application_id` / `identity_id` / `event_id` / `tour_id` / `owner_id` / `account_id` / 会員番号が含まれない |
| AC-SW-23 | `GET /v1/shares` items に `edit_count` / `last_edited_at` が入る |
| AC-SW-24 | 削除済み application の行は matrix に出ない → PATCH は 404。scope tour が論理削除済み → `SHARE_INVALID` 404（内部 id を message に出さない） |
| AC-SW-25 | **`GET /v1/tours/:id/matrix` のレスポンスキーが 1 つも変わらない**（`application_updated_at` が漏れない） |
| AC-SW-26 | PATCH のレスポンスヘッダに `X-Robots-Tag: noindex, nofollow` |
| AC-SW-27 | 同一 token への PATCH を上限超過 → `RATE_LIMITED` 429 |
| AC-SW-28 | 編集成功のログに `share_link_id` / `application_id` / 変更キー名が出て、**値（座席文字列）は出ない** |

---

## 7. 検証ゲート（各タスクの完了条件）

```bash
cd apps/api && npx tsc --noEmit
cd apps/api && npm test
cd apps/api && npm run build
```

加えて:

- **T0**: `npx prisma validate` と `npx prisma db push`（ローカル DB 起動時）。`npx prisma generate` 後に T1/T2 へ引き渡す。**`resend` の採否を報告に明記**（§3.1）
- **T1 / T2**: 上記 3 コマンドが Green。**既存 spec の変更は §5.6 の一覧に限る**（それ以外を書き換えていたら差し戻し）
- 実 DB 疎通（`make up` → `make health` → 手動 curl）は T1/T2 完了後にオーケストレーターが実施:
  - `POST /v1/auth/register` → `GET /v1/me`（`auth_providers` が `["email"]`）
  - `POST /v1/auth/password/reset-request` →（非本番なのでログにコードが出る）→ `POST /v1/auth/password/reset` → 旧パスワードで login が 401 / 新パスワードで 200
  - `POST /v1/shares`（`permission:"write"`・公演 3 件）→ `GET /public/shares/:token` → `PATCH .../items/:item_key` → 再 GET で `status` が変わっている
  - 同じ `rev` で 2 回目の PATCH → 409
  - 公演を 4 件に増やしてから Free で write 発行 → 403（`details:{limit:3,current:4}`）。既存リンクは有効のまま 4 公演目が `editable:false`

完了報告は ①変更ファイル ②実行した検証コマンドと結果 ③残課題（rule 05）。

---

## 8. ハンドオフ（委譲プロンプト案）

共通の前置き（rule 06 の 7 要素）:

> まず `.claude/skills/implementing-robustly/SKILL.md` を読み、従うこと。
> リポジトリ: `/Users/yuyamorishita/オタ活アプリ`。作業対象は `apps/api`。
> 契約の正: `/Users/yuyamorishita/オタ活アプリ/docs/plans/backend-domain-modules/api-contract.md` と
> `/Users/yuyamorishita/オタ活アプリ/docs/plans/backend-auth-and-shares-extension/api-contract-delta.md`。
> **契約に書かれたパス・メソッド・JSON キー・enum 値を変えない。** 変更が要るなら実装を止めて報告する。
> 受入基準は `docs/plans/backend-auth-and-shares-extension/plan.md` §6。**先に失敗する `*.spec.ts` を書いてから実装する（Red→Green）**。
> 禁止事項: `.claude/rules/feedback_review_patterns.md` の BE-1〜BE-6。特に BE-3（Controller / UseCase から Prisma を直接触らない）と BE-4（ownerId スコープ）。
> 報告は日本語で ①変更ファイル（file:line）②実行した検証コマンドと結果 ③残課題。

### Wave 0（単独発行）

> `nest-developer`（sonnet）: plan.md §3（T0）を実装する。**触ってよいのは `package.json` / `prisma/schema.prisma` / `src/common/errors/error-codes.ts` / `src/common/throttling/` / `src/mail/` / `src/app.module.ts` / `docker-compose.yml` / `apps/api/.env.example` のみ**。auth / shares / public のロジックには一切触らない。AC-T0-01〜08。`npx prisma db push` は `apps/api/` で実行する（BE-5）。**`resend` が ts-jest（CJS）で動かない場合は依存を外して fetch 直叩き実装に切り替え、その旨を報告に明記すること**（判断は自分で下してよい）。

### Wave 1（1 メッセージで 2 エージェント並列発行）

> A. `nest-developer`（**opus**）: plan.md §4（T1・auth）。**触ってよいのは `src/auth/**` と `src/me/me.service.ts`(+spec) のみ**。実装順は ①OIDC 共通化 + Google ②Email/Password ③リセット。既存 `apple-*.spec.ts` は 1 行も変えずに Green を保つこと（AC-GA-11）。既存例: `src/auth/apple-token.verifier.ts`（RS256 自前検証）・`src/auth/auth.service.ts:62-101`（find-or-create + P2002 リカバリ）・`src/auth/auth.service.ts:137-193`（トークンはハッシュのみ保存）。メール送信は T0 が用意する `MailSender` 抽象に注入で依存し、**spec ではスタブに差し替えてネットワークに出ない**こと。AC-GA-01〜13 / AC-EP-01〜15 / AC-PR-01〜13。

> B. `nest-developer`（**opus**）: plan.md §5（T2・共有 write）。**触ってよいのは `src/shares/**` / `src/public/**` / `src/entitlements/**` / `src/tours/tour-matrix.service.ts`(+spec) / `src/app.setup.ts`(+spec) のみ**。`src/applications/**` は変更せず `ApplicationsService` を再利用する。`public-share.presenter.ts` の「内部 UUID を一切出さない」不変条件を壊さない。**公開エンドポイントの 403 で理由（プラン超過か非公開名義か）を区別しない**こと。既存例: `src/public/use-cases/resolve-share.use-case.ts`（判定順序と SHARE_INVALID への畳み込み）・`src/entitlements/entitlements.service.ts`（`identityLimit` / `shareLimit` の形）。AC-SW-01〜28。

### Wave 2

> `code-reviewer`（opus・**別セッション**）: 差分は T0+T1+T2 の全変更。観点は rule 04 + `feedback_review_patterns.md`。特に ①公開 write の認可順序と情報漏洩（403/404 の使い分け・**プラン状態を漏らしていないか**）②`public-share.presenter.ts` のマスキング不変条件 ③パスワード平文・リセットコードがログ / 例外 / レスポンスに出ていないか ④リセットの列挙耐性（未登録でも 202・同一エラー）⑤既存契約の後方互換（read リンクのペイロード形・`POST /v1/shares` の既定）⑥`GET /v1/tours/:id/matrix` のキーが変わっていないか。結果は `docs/plans/backend-auth-and-shares-extension/review.md`。**スコープ外**: メール確認フロー / アカウント統合 / `boards` / 法務ドキュメント本文。

### Wave 3（docs 反映 / T3）

`requirements.md` §6「docs」の 6 ファイル。特に:

- `docs/07-monetization.md`: 機能比較表に「共有リンクの共同編集（write）: Free △ 公演 3 件まで / Plus ○」を追加（`requirements.md` C8 の追記案）
- `docs/08-compliance-risk.md`: `:522` の「Sign in with Apple のみ」を修正 + **委託先一覧に Resend を追記**
- `docs/09-roadmap.md`: write 共有リンクの Phase 1 前倒し（Q9 の最終確認）

---

## 9. iOS 側への申し送り（本計画では実装しない）

`docs/plans/ios-network-integration/` の担当者へ:

1. **T1（認証）の待ちが解ける**: `POST /v1/auth/google`（`id_token` キー）/ `register`（201）/ `login` / `password/reset-request`（202）/ `password/reset`。レスポンス形は Apple と同一なのでパースは 1 つで済む
2. **パスワードリセットは 8 桁コード方式**。「メールに届いたコードを入力 → 新パスワード」の 2 画面が要る。ディープリンク基盤は不要
3. **同じメールで Apple / Google / メール登録をすると別アカウントになる**。アカウント画面に現在のログイン方法（`GET /v1/me.auth_providers`）を表示する
4. **共有ボードの編集（オーナー側）は `PATCH /v1/applications/:id`（Bearer）を使う**。公開 write は共有先（未認証 Web）専用（`requirements.md` C5）
5. **write リンクは「URL を知っていれば誰でも編集できるリンク」**。発行 UI（`ShareRecipientsView`）でこの性質を明示する（C6）
6. **Free も write 共有を発行できる。ただし公演 3 件まで**。超過時は `PLAN_LIMIT_SHARE_WRITE` 403（`details:{limit,current}`）をそのまま文言に使える。**発行後に公演が増えると超過分は `editable:false` になる**ので、共有中の tour に公演を足したときの表示を考えておく
7. `contract-mapping.md` の更新は iOS 計画側の責務

---

## 10. 本計画のスコープ外

`requirements.md` §7 を参照。要点: メール確認（verification）/ メールアドレス変更 / アカウント統合 / `boards` による本格的な共同編集 / 共有編集履歴の閲覧 API / Redis バックエンドのレート制限 / Web の編集 UI / iOS 実装 / 退会 / `docs/08` 法務文書本文への Resend 追記（**ストア提出前に必須の残課題**）。
