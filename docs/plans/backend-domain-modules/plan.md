# plan — backend-domain-modules

前提: `requirements.md`（要件・制約・エッジケース）/ `api-contract.md`（**契約の正**）/ `questions-requirements.md`（未確定事項の暫定確定）。

実装は **Red → Green**（受入基準を失敗する `*.spec.ts` に翻訳してから実装）。spec は jest 設定上 **`apps/api/src/` 配下**に置く（`package.json:65` `rootDir: src`）。

---

## 1. タスク一覧と依存関係

| Task | 内容 | 依存 | 担当候補 | 目安 |
|---|---|---|---|---|
| **T0** | 基盤（依存追加・common・schema・app.module・main.ts・空モジュール雛形・entitlements 読み取り） | — | `nest-developer` **model: opus** | 1.0 人日 |
| **T1** | `auth/`（Apple 検証・JWT 発行・refresh 回転・logout） | T0 | `nest-developer` **model: opus** | 1.5 人日 |
| **T2** | `me/`（GET / PATCH プロフィール） | T0 | `nest-developer` (sonnet) | 0.5 人日 |
| **T3** | `identities/`（CRUD + `PLAN_LIMIT_IDENTITY` + `assertOwned`） | T0 | `nest-developer` (sonnet) | 1.0 人日 |
| **T4** | `memberships/`（CRUD + 親所有者検証） | T3 | `nest-developer` (sonnet) | 0.7 人日 |
| **T5** | `tours/` `events/` `applications/`（find-or-create TX・companions・matrix） | T3 | `nest-developer` **model: opus** | 2.0 人日 |
| **T6** | `shares/` `public/`（発行・一覧・失効・公開解決 + マスキング） | T5 | `nest-developer` **model: opus** | 1.5 人日 |
| **T7** | `code-reviewer`（別セッション・全差分） | T1〜T6 | `code-reviewer` (opus) | 0.5 人日 |

依存グラフ:

```
T0 ──┬── T1 (auth)
     ├── T2 (me)
     └── T3 (identities) ──┬── T4 (memberships)
                           └── T5 (tours/events/applications) ── T6 (shares/public)
```

**model エスカレーション理由**（rule 02）: T0 は前例なしの横断基盤、T1 は認証、T5 は複数モデルの 1TX 整合、T6 はマスキング（漏洩事故に直結）。T2 / T3 / T4 は既存パターンに沿う定型 CRUD。

---

## 2. 並列実行可能なタスク

| Wave | 並列実行するタスク | 備考 |
|---|---|---|
| Wave 0 | **T0 単独（直列必須）** | `schema.prisma` / `app.module.ts` / `main.ts` / `package.json` を触る唯一のタスク。ここで DB 変更（`prisma db push`）まで完了させる |
| Wave 1 | **T1・T2・T3 を同一メッセージで並列発行** | ファイル重複なし（`src/auth/` `src/me/` `src/identities/`）。T0 が空モジュール雛形と `app.module.ts` 登録を済ませているため誰も共有ファイルを触らない |
| Wave 2 | **T4・T5 を並列発行** | どちらも T3 の `IdentitiesService.assertOwned` に依存。`src/memberships/` と `src/tours/ src/events/ src/applications/` でファイル重複なし |
| Wave 3 | T6 単独 | T5 の `TourMatrixService` を再利用するため直列 |
| Wave 4 | T7（レビュー）単独 | 実装が並列でもレビューは集約（rule 03） |

### 同時に触らせないファイル（rule 03）

| ファイル | 唯一の編集者 |
|---|---|
| `apps/api/prisma/schema.prisma` | T0 |
| `apps/api/src/app.module.ts` | T0 |
| `apps/api/src/main.ts` | T0 |
| `apps/api/package.json` | T0 |
| `apps/api/.env.example` | T0 |
| `apps/api/src/common/**` | T0（Wave 1 以降は読み取り専用。追加が必要なら planner に差し戻す） |
| `apps/api/src/entitlements/**` | T0 |

---

## 3. T0: 基盤タスクの詳細（並列化の前提を作るタスク）

### 3.1 依存追加（`apps/api/package.json`）

```
@nestjs/config @nestjs/jwt class-validator class-transformer jose uuid
```

- `jose`: Apple JWKS の取得と JWT 検証（`createRemoteJWKSet` + `jwtVerify`）。`jwks-rsa` + `jsonwebtoken` の組み合わせより依存が少ない
- `uuid`: サーバー側 UUID 生成（`request_id`・share `id`・tour `id` 省略時）

### 3.2 `prisma/schema.prisma` の変更（**T0 のみ**）

追加モデル:

```prisma
model RefreshToken {
  id         String    @id @db.Uuid
  userId     String    @map("user_id") @db.Uuid
  tokenHash  String    @unique @map("token_hash")
  expiresAt  DateTime  @map("expires_at") @db.Timestamptz(6)
  revokedAt  DateTime? @map("revoked_at") @db.Timestamptz(6)
  replacedBy String?   @map("replaced_by") @db.Uuid
  createdAt  DateTime  @default(now()) @map("created_at") @db.Timestamptz(6)

  user User @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@index([userId], map: "refresh_tokens_user_idx")
  @@map("refresh_tokens")
}
```

既存モデルへの追加:

| モデル | 追加 |
|---|---|
| `User` | `refreshTokens RefreshToken[]` |
| `Event` | `startsAt DateTime? @map("starts_at") @db.Timestamptz(6)` |
| `Membership` | `rank String?` / `autoRenew Boolean @default(false) @map("auto_renew")` / `applications Application[]` |
| `Application` | `repMembershipId String? @map("rep_membership_id") @db.Uuid` / `roundName String? @map("round_name")` / `ticketCount Int @default(1) @map("ticket_count")` / `priceYen Int? @map("price_yen")` / `repMembership Membership? @relation(fields: [repMembershipId], references: [id], onDelete: SetNull)` |

反映: `cd apps/api && npx prisma db push`（**必ず `apps/api/` で実行** — BE-5）。

### 3.3 `src/common/`

| ファイル | 内容 |
|---|---|
| `errors/app-error.ts` | `AppError extends HttpException`。`code` / `message` / `details` / `status` |
| `errors/error-codes.ts` | `api-contract.md` §0 のコード定数 |
| `filters/all-exceptions.filter.ts` | 全例外を envelope に正規化。`request_id` は `X-Request-Id` or 生成。未知例外は `INTERNAL` 500 + スタックはログのみ |
| `interceptors/request-id.interceptor.ts` | `X-Request-Id` の受理・生成・レスポンスヘッダ付与 |
| `decorators/public.decorator.ts` | `@Public()`（`SetMetadata('isPublic', true)`） |
| `decorators/current-user.decorator.ts` | `@CurrentUser()` → `req.user.id`（string） |
| `guards/jwt-auth.guard.ts` | `APP_GUARD`。docs/04 §2 の実装そのまま。`@Public` を素通し |
| `dto/pagination.dto.ts` | `limit`（1〜200・既定50）/ `cursor` |
| `util/date.util.ts` | `toDateOnly(s: string): Date` / `fromDateOnly(d: Date \| null): string \| null`（UTC 固定） |
| `util/hash.util.ts` | `sha256Hex(raw: string): string` / `randomToken(bytes = 32): string`（base64url） |

### 3.4 `src/entitlements/`（読み取り専用）

- `EntitlementsService.get(userId)`: 行が無ければ `{ plan: 'free', bonusIdentitySlots: 0 }` 相当を返す（E-5）
- `identityLimit(userId): Promise<number | null>`: `plus` 有効 or 猶予中 → `null`（無制限）。それ以外 `3 + (bonusExpiresAt > now ? bonusIdentitySlots : 0)`
- `shareLimit(userId): Promise<number | null>`: `plus` → `null`、`free` → `1`
- **書き込みメソッドを作らない**（ADR-002）

### 3.5 `src/main.ts` / `src/app.module.ts`

- `setGlobalPrefix('v1', { exclude: ['health', 'readyz', 'public/shares/:token'] })`
- `useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }))`
- `useGlobalFilters(new AllExceptionsFilter())`
- CORS は既存の `CORS_ORIGINS` 方式を維持（`main.ts:7-13`）
- `AppModule` に `ConfigModule.forRoot({ isGlobal: true })` / `JwtModule.register({ global: true })` / `APP_GUARD` / **全ドメインモジュールの import を先に登録**

### 3.6 空モジュール雛形（Wave 1 以降が `app.module.ts` を触らないため）

`src/auth/auth.module.ts` / `me/me.module.ts` / `identities/identities.module.ts` / `memberships/memberships.module.ts` / `tours/tours.module.ts` / `events/events.module.ts` / `applications/applications.module.ts` / `shares/shares.module.ts` / `public/public.module.ts` を **`@Module({})` の空定義**で作成し、`app.module.ts` の `imports` に列挙する。各 Wave の担当は自分のモジュールファイル内だけを埋める。

### 3.7 `.env.example` 追記

`JWT_ACCESS_SECRET` / `JWT_ACCESS_TTL_SECONDS`（既定 3600）/ `REFRESH_TTL_DAYS`（既定 30）/ `APPLE_CLIENT_ID` / `APPLE_ISSUER` / `APPLE_JWKS_URL` / `SHARE_BASE_URL`

---

## 4. 受入基準 → テストケース

各 AC は 1 つ以上の `it()` に対応させる。**先に落ちるテストを書く（Red）**。

### T0（基盤）

| AC-ID | 受入基準 | テスト |
|---|---|---|
| AC-CORE-01 | `AllExceptionsFilter` が `AppError` を `{code,message,details,request_id}` に正規化する | `src/common/filters/all-exceptions.filter.spec.ts` |
| AC-CORE-02 | 未知例外は `INTERNAL` 500 になり、メッセージにスタックが含まれない | 同上 |
| AC-CORE-03 | `JwtAuthGuard` は Bearer 無しで `UNAUTHENTICATED` 401 を投げる | `src/common/guards/jwt-auth.guard.spec.ts` |
| AC-CORE-04 | `@Public()` 付きハンドラはトークン無しで通過する | 同上 |
| AC-CORE-05 | 不正な access token は `UNAUTHENTICATED` 401 | 同上 |
| AC-CORE-06 | `toDateOnly('2026-08-20')` → `2026-08-20T00:00:00.000Z`、`fromDateOnly` で往復一致（TZ を `Asia/Tokyo` に設定しても） | `src/common/util/date.util.spec.ts`（E-12） |
| AC-CORE-07 | `identityLimit`: free=3 / free+有効bonus2=5 / free+期限切れbonus=3 / plus=null / entitlement 行なし=3 | `src/entitlements/entitlements.service.spec.ts`（E-4・E-5） |
| AC-CORE-08 | `shareLimit`: free=1 / plus=null | 同上 |

### T1（auth）

| AC-ID | 受入基準 | テスト |
|---|---|---|
| AC-AUTH-01 | 有効な identity token で新規ユーザーが作られ、`profile`（`account_id` 採番済み）と `entitlement(free)` が同一 TX で作られる | `src/auth/use-cases/sign-in-with-apple.use-case.spec.ts` |
| AC-AUTH-02 | 既存 `apple_sub` の再ログインはユーザーを重複作成せず `is_new: false` を返す | 同上 |
| AC-AUTH-03 | 署名不正 / `aud` 不一致 / `exp` 切れの token は `AUTH_APPLE_INVALID` 401 | `src/auth/apple-token.verifier.spec.ts`（E-14） |
| AC-AUTH-04 | req に `nonce` があり token の `nonce` と不一致なら 401、req に nonce が無ければ検証しない | 同上 |
| AC-AUTH-05 | レスポンスの `refresh_token` は DB に平文で保存されず `sha256` hex のみが入る | `src/auth/auth.service.spec.ts` |
| AC-AUTH-06 | `refresh` は旧トークンを `revoked_at` にし、新しい access + refresh を返す | `src/auth/use-cases/refresh-token.use-case.spec.ts` |
| AC-AUTH-07 | 失効済み / 期限切れ / 未知の refresh は `AUTH_REFRESH_INVALID` 401 | 同上（E-13） |
| AC-AUTH-08 | `logout` は該当 refresh を失効させ 204。未知でも 204 | `src/auth/auth.controller.spec.ts` |
| AC-AUTH-09 | Apple の email は初回のみ保存し、2回目以降 `null` が来ても既存値を上書きしない | `src/auth/use-cases/sign-in-with-apple.use-case.spec.ts` |
| AC-AUTH-10 | `account_id` は `^ACC-[0-9A-F]{6}$`。衝突時は最大5回リトライ | `src/auth/account-id.generator.spec.ts`（E-15） |

### T2（me）

| AC-ID | 受入基準 | テスト |
|---|---|---|
| AC-ME-01 | `GET /v1/me` が user / profile / entitlement を `api-contract.md` §2 の形で返す | `src/me/me.service.spec.ts` |
| AC-ME-02 | `auth_providers` が `apple_sub` / `google_sub` / `email` の有無から導出される | 同上 |
| AC-ME-03 | `PATCH` で `theme_color: "blue"` は `VALIDATION_ERROR` 400 | `src/me/dto/update-me.dto.spec.ts` |
| AC-ME-04 | `PATCH` で `account_id` を送ると 400（黙って無視しない） | 同上（FR-ME-3） |
| AC-ME-05 | `PATCH` は送られたキーのみ更新し、未指定キーを null で潰さない | `src/me/me.service.spec.ts` |
| AC-ME-06 | `entitlement` への書き込みメソッドが me モジュールに存在しない | 静的確認（レビュー観点） |

### T3（identities）

| AC-ID | 受入基準 | テスト |
|---|---|---|
| AC-IDT-01 | 作成時 `owner_id` はリクエストではなく `currentUser.id` から設定される | `src/identities/identities.service.spec.ts`（BE-4） |
| AC-IDT-02 | free で 3 件保持時の 4 件目は `PLAN_LIMIT_IDENTITY` 403 + `details:{limit:3,current:3}` | `src/identities/use-cases/create-identity.use-case.spec.ts` |
| AC-IDT-03 | ソフトデリート済みは上限にカウントされない（3件中1件削除 → 作成成功） | 同上（E-3） |
| AC-IDT-04 | 有効な bonus 枠があると上限が 3+bonus になる | 同上 |
| AC-IDT-05 | plus は 4 件目以降も作成できる | 同上 |
| AC-IDT-06 | 他人の identity id への `GET` / `PATCH` / `DELETE` は `NOT_FOUND` 404 | `identities.service.spec.ts`（BE-4・C5） |
| AC-IDT-07 | `relation: "boss"` は 400。`other` に落とさない | `src/identities/dto/create-identity.dto.spec.ts`（BE-2） |
| AC-IDT-08 | `id` に UUID v7 文字列を渡して 400 にならない | 同上（BE-1） |
| AC-IDT-09 | 既存 id の再 POST は `CONFLICT` 409 | `create-identity.use-case.spec.ts`（E-1） |
| AC-IDT-10 | `DELETE` は行を消さず `deleted_at` を立てる。2回目も 204 | `identities.service.spec.ts` |
| AC-IDT-11 | `history_visible` 省略時の既定が `false` | `create-identity.use-case.spec.ts`（FR-ID-8） |
| AC-IDT-12 | `assertOwned` が他人 / 削除済み id で `NOT_FOUND` を投げる | `identities.service.spec.ts` |

### T4（memberships）

| AC-ID | 受入基準 | テスト |
|---|---|---|
| AC-MB-01 | 他人の `identity_id` 配下には作成できず 404 | `src/memberships/memberships.service.spec.ts`（BE-4） |
| AC-MB-02 | `owner_id` は親 identity から継承される（リクエスト値を使わない） | 同上（FR-MB-3） |
| AC-MB-03 | `member_no` を含むボディは `VALIDATION_ERROR` 400 | `src/memberships/dto/create-membership.dto.spec.ts`（FR-MB-4） |
| AC-MB-04 | `member_no_last4` が 5 文字なら 400 | 同上 |
| AC-MB-05 | `fee_yen: -1` / `1000001` は 400 | 同上 |
| AC-MB-06 | `?identity_id=` で自分の該当 identity 分のみ返る | `memberships.service.spec.ts` |
| AC-MB-07 | `DELETE` はソフトデリート | 同上 |
| AC-MB-08 | `renewal_on: "2026-09-15"` が往復して同じ文字列で返る | `src/memberships/memberships.presenter.spec.ts`（E-12） |

### T5（tours / events / applications）

| AC-ID | 受入基準 | テスト |
|---|---|---|
| AC-APP-01 | 同名 tour が既にある場合、新規 tour を作らず既存を再利用する | `src/applications/use-cases/create-application.use-case.spec.ts` |
| AC-APP-02 | ソフトデリート済み同名 tour がある場合、`deleted_at` を null にして再利用する | 同上（E-2・FR-AP-2） |
| AC-APP-03 | tour / event / application / companions が単一 `$transaction` 内で作られる | 同上 |
| AC-APP-04 | 他人の `rep_identity_id` 指定で 404 になり、tour / event も作られない（ロールバック） | 同上（E-17） |
| AC-APP-05 | `rep_membership_id` が `rep_identity_id` に属さない場合 404 | 同上（FR-AP-4） |
| AC-APP-06 | companions 4 件は `VALIDATION_ERROR` 400 | `src/applications/dto/create-application.dto.spec.ts`（FR-AP-5） |
| AC-APP-07 | companions の `identity_id` 重複は 400 | 同上（E-7） |
| AC-APP-08 | companions 0 件で作成でき、レスポンスは `companions: []` | `create-application.use-case.spec.ts`（E-6） |
| AC-APP-09 | `status: "pending"` は 400。`applied` に落とさない | `create-application.dto.spec.ts`（BE-2） |
| AC-APP-10 | `status` 省略時は `applied` | `create-application.use-case.spec.ts` |
| AC-APP-11 | `PATCH` の `companions` 全置換: 既存3件 → 1件指定で残り2件が `deleted_at` を持つ | `src/applications/use-cases/update-application.use-case.spec.ts`（FR-AP-8） |
| AC-APP-12 | `PATCH` に `companions` キーが無ければ companions は変更されない | 同上 |
| AC-APP-13 | `PATCH` で `companions: []` は全件ソフトデリート | 同上（E-16） |
| AC-APP-14 | `PATCH` で `event_id` を送ると 400 | `src/applications/dto/update-application.dto.spec.ts` |
| AC-APP-15 | `GET /v1/applications?limit=0` / `limit=500` は 400 | `src/common/dto/pagination.dto.spec.ts`（E-18） |
| AC-APP-16 | カーソルページング: `next_cursor` は返却最終要素の `updated_at`、`has_more` が正しい | `src/applications/applications.service.spec.ts` |
| AC-APP-17 | 全クエリに `owner_id` 条件が付く（他人の application は一覧・単体とも見えない） | 同上（BE-4） |
| AC-APP-18 | matrix が `event_date asc` で、`deleted_at` 付き event / application を含まない | `src/tours/tour-matrix.service.spec.ts` |
| AC-APP-19 | matrix の `companion_names` は配列で、`identity_id` があれば identity の現在名を使う | 同上（FR-AP-13） |
| AC-APP-20 | 他人の tour の matrix は 404 | 同上 |
| AC-APP-21 | tour の `DELETE` で配下 event / application が削除されない | `src/tours/tours.service.spec.ts`（C4） |
| AC-APP-22 | `POST /v1/tours` / `POST /v1/events` のルートが存在しない | Controller のルート定義確認（レビュー観点・D9） |

### T6（shares / public）

| AC-ID | 受入基準 | テスト |
|---|---|---|
| AC-SH-01 | 発行レスポンスに生トークンが含まれ、DB には `sha256` hex のみが保存される | `src/shares/use-cases/create-share.use-case.spec.ts`（FR-SH-1） |
| AC-SH-02 | free で有効リンク 1 本保持時の 2 本目は `PLAN_LIMIT_SHARE` 403 | 同上（Q7） |
| AC-SH-03 | 失効済み / 期限切れリンクは上限にカウントされない | 同上 |
| AC-SH-04 | `expires_at` 省略時に +30 日が設定される | 同上（Q8） |
| AC-SH-05 | `expires_at` が +366 日は 400 | `src/shares/dto/create-share.dto.spec.ts` |
| AC-SH-06 | `scope_type: "identity_summary"` に `scope_id` を送ると 400 | 同上（FR-SH-2） |
| AC-SH-07 | 他人の `scope_id`（tour）指定は 404 | `create-share.use-case.spec.ts` |
| AC-SH-08 | `shared_with_account_ids` に `"ABC-123"` は 400、`["ACC-3F9A21"]` は通る | `create-share.dto.spec.ts` |
| AC-SH-09 | `GET /v1/shares` のレスポンスに `token` / `token_hash` キーが存在しない | `src/shares/shares.presenter.spec.ts`（FR-SH-6） |
| AC-SH-10 | `DELETE /v1/shares/:id` で `revoked_at` が入り 204。2回目も 204 | `src/shares/shares.service.spec.ts` |
| AC-SH-11 | 未知トークン / 失効済み / 期限切れはすべて `SHARE_INVALID` 404（区別しない） | `src/public/use-cases/resolve-share.use-case.spec.ts`（FR-SH-8・E-9） |
| AC-SH-12 | 期限ちょうど（`expires_at === now`）は無効 | 同上（E-8） |
| AC-SH-13 | 有効閲覧で `view_count` が +1 され `last_viewed_at` が更新される | 同上 |
| AC-SH-14 | 無効アクセスでは `view_count` が増えない | 同上（E-9） |
| AC-SH-15 | `history_visible=false` の名義行は `rep_name="非公開の名義"` / `rep_color=null` / `seat=null` | 同上（FR-SH-9・E-11） |
| AC-SH-16 | 公開レスポンスの JSON 文字列に `member_no` / `owner_id` / `account_id` / `shared_with` が含まれない | 同上（FR-SH-10）— スナップショットではなくキー走査で検証する |
| AC-SH-17 | application 0 件の tour 共有は 200 + `items: []`（404 にしない） | 同上（E-10） |
| AC-SH-18 | `identity_summary` は `visible:false` の名義について件数キーを含めない | 同上（D10） |
| AC-SH-19 | `GET /public/shares/:token` は `@Public()` で Bearer 無しに 200 を返す | `src/public/public.controller.spec.ts` |
| AC-SH-20 | レスポンスに `X-Robots-Tag: noindex, nofollow` が付く | 同上 |

---

## 5. テスト方針（DB・ネットワーク非依存）

- `PrismaService` は `jest.fn()` ベースのモックを DI する。`$transaction(cb)` のモックは `cb(txMock)` を同期実行し、**例外時にロールバック相当（後続の書き込みが呼ばれないこと）を assert** する
- `AppleJwksClient` はインターフェースで DI。spec では固定 JWK / 署名済みテスト用 JWT（`jose` でその場生成）を使い、外部通信しない
- DTO のバリデーションは `plainToInstance` + `validate`（class-validator）を直接呼ぶ spec で検証する（Controller を通さない）
- `Date.now()` に依存する判定（上限・期限）は `jest.useFakeTimers().setSystemTime(...)` で固定する
- `date.util` の TZ テストは `process.env.TZ = 'Asia/Tokyo'` を spec 冒頭で設定する

---

## 6. 検証ゲート（各タスクの完了条件）

```bash
cd apps/api && npx tsc --noEmit
cd apps/api && npm test
cd apps/api && npm run build
```

T0 のみ追加で:

```bash
cd apps/api && npx prisma validate
cd apps/api && npx prisma generate
make db-only && cd apps/api && npx prisma db push   # ローカル DB がある場合
make up && make health
```

**「完了しました」だけの報告は不可**。①変更ファイル ②実行した検証コマンドと結果 ③残課題 を必須とする（rule 05）。

---

## 7. ハンドオフ（委譲プロンプト案）

すべての委譲プロンプトに以下を含める（rule 06 の 7 要素）:

- 冒頭: 「まず `/Users/yuyamorishita/オタ活アプリ/.claude/skills/implementing-robustly/SKILL.md` を読み、従うこと」
- 契約: 「API 契約の正は `/Users/yuyamorishita/オタ活アプリ/docs/plans/backend-domain-modules/api-contract.md`。**パス・メソッド・JSON キー・enum 値を変更しない**。変更が必要なら実装を止めて報告する」
- 禁止: 「`prisma/schema.prisma` / `app.module.ts` / `main.ts` / `package.json` / `src/common/**` / `src/entitlements/**` を編集しない（T0 の担当範囲）。必要になったら止めて報告する」
- 頻出バグ: 「`/Users/yuyamorishita/オタ活アプリ/.claude/rules/feedback_review_patterns.md` の **BE-1（UUID v7・`@IsUUID('4')` 禁止）/ BE-2（enum 黙殺禁止）/ BE-3（Controller・UseCase から Prisma 直叩き禁止）/ BE-4（`ownerId` スコープ）/ BE-5（prisma は `apps/api/` で実行）** を守る」
- 手順: 「対応する AC-ID の `*.spec.ts` を先に書いて落ちること（Red）を確認してから実装する（Green）」
- 完了条件: §6 の検証ゲート
- 報告: 「日本語で ①変更ファイル（file:line）②実行した検証コマンドと結果 ③残課題」

### Wave 0（単独発行）

> T0。`docs/plans/backend-domain-modules/plan.md` §3 のとおり基盤を作る。§4 の AC-CORE-01〜08 を満たすこと。**空モジュール雛形（§3.6）を必ず作り `app.module.ts` に登録すること**（後続タスクが `app.module.ts` を触らないため）。

### Wave 1（1メッセージで 3 エージェント並列）

> T1（`src/auth/`・model opus）/ T2（`src/me/`）/ T3（`src/identities/`）。それぞれ自分のディレクトリのみ編集する。参照する既存例: `apps/api/src/health/health.controller.ts:4-18`（Controller の書き方）、`apps/api/src/prisma/prisma.service.ts:4-16`（PrismaService の注入）。

### Wave 2（1メッセージで 2 エージェント並列）

> T4（`src/memberships/`）/ T5（`src/tours/` `src/events/` `src/applications/`・model opus）。どちらも `IdentitiesService.assertOwned(userId, id, tx?)` を注入して親所有者を検証する（自前で `prisma.identity` を叩かない）。

### Wave 3

> T6（`src/shares/` `src/public/`・model opus）。matrix のデータ組立は T5 の `TourMatrixService` を再利用し、**マスキングだけを shares 側で適用**する（ロジックを二重に書かない）。

### Wave 4

> **別セッションで** `code-reviewer`（model opus）。差分範囲: T0〜T6 の全変更。観点は rule 04 の 7 項目 + `feedback_review_patterns.md` BE-1〜BE-5 + `api-contract.md` との一致（特に公開共有レスポンスのマスキングと `token` 非露出）。結果は `docs/plans/backend-domain-modules/review.md` に保存。スコープ外（指摘不要）: sync / billing / home / stats / device_tokens / 共有 Web / iOS。

---

## 8. 本計画のスコープ外（着手しない）

`questions-requirements.md` Q14 の確認事項。**実装エージェントがついでに作らないこと。**

`sync/`（pull / push・LWW）/ `billing/`（RevenueCat Webhook・`entitlements` 書き込み）/ `home/summary` / `stats/identities` / `v_*` DB ビュー / `device_tokens`（APNs）/ Next.js 共有 Web / Google・メール認証 / RLS・pgTAP / iOS 側の追従実装 / CI・pre-commit hook。

---

## 9. 実装後にやること（planner ではなくオーケストレーターの責務）

1. `docs/04-api.md` を `api-contract.md` §9 の D1〜D10 に合わせて更新
2. `docs/02-architecture.md` §7 Q4（refresh token 保存方式）を「決定済み: DB テーブル + 回転式 opaque」に更新
3. `CLAUDE.md`「既知の未整備」の「NestJS ドメインモジュールは雛形段階」を実態に合わせて更新
4. iOS 追従（`Packages/Network` 新設 + Domain / Features の契約追従）を別計画として起票。`questions-requirements.md` §E の E1〜E7 が入力になる
