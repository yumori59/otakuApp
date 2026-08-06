# requirements — backend-domain-modules

**目的**: `apps/api` に認証〜共有リンクまでのドメインモジュール一式を実装し、iOS クライアント（実装済み14画面）がローカル完結からサーバー接続へ移行できる状態にする。

**位置づけ**: docs/09 Phase 1 の 1-1（NestJS 骨格の残り）/ 1-2（Sign in with Apple + 自前 JWT）/ 1-6（共有リンク発行）+ 1-10 のサーバー側（名義数制限）。
**1-3（同期エンジン）・1-5（集計・統計）・1-9（課金）・1-7（共有 Web）は本計画に含めない**（`questions-requirements.md` Q14）。

前提の暫定確定は `questions-requirements.md` の `[Assumed]` に従う。API 契約の正は `api-contract.md`。

---

## 1. 現状把握（実装着手前の事実）

| # | 事実 | 根拠 |
|---|---|---|
| F1 | BE は `health` / `prisma` のみ。ドメインモジュールは 1 つも無い | `apps/api/src/` 配下は `app.module.ts` / `main.ts` / `health/` / `prisma/` の 6 ファイル |
| F2 | `app.module.ts` は `PrismaModule` / `HealthModule` の 2 imports のみ | `apps/api/src/app.module.ts:6` |
| F3 | `main.ts` にグローバルプレフィックス・ValidationPipe・例外フィルタが無い。CORS は `CORS_ORIGINS` env のみ | `apps/api/src/main.ts:5-13` |
| F4 | 認証・検証・JWT の依存が未インストール（`@nestjs/config` / `@nestjs/jwt` / `class-validator` / `class-transformer` / JWKS 検証ライブラリがいずれも無い） | `apps/api/package.json:25-32` |
| F5 | jest は `rootDir: src` / `testRegex: .*\.spec\.ts$` / `passWithNoTests: true`。**spec は `src/` 配下に置く** | `apps/api/package.json:59-76` |
| F6 | `PrismaService` は `PrismaClient` を継承した薄いラッパー。Prisma 拡張・ミドルウェアは未導入 | `apps/api/src/prisma/prisma.service.ts:4-16` |
| F7 | Prisma スキーマは 11 モデルが揃っているが、docs/04 の契約に必要なカラムが一部欠落（Q1） | `apps/api/prisma/schema.prisma` |
| F8 | refresh token を保存するモデルが無い | 同上 |
| F9 | iOS は Domain 層に純ローカルのストアを持つのみ。Network / DataStore パッケージは未作成 | `meigicho/Packages/` に `Core` / `DesignSystem` / `Domain` / `Features` の4つのみ |
| F10 | iOS の `Relation` / `ApplicationStatus` enum 値は DB の CHECK 値と一致している | `meigicho/Packages/Domain/Sources/Domain/Enums/AppEnums.swift:3-24` |

---

## 2. 機能要件

### 2.1 auth（Sign in with Apple + 自前 JWT）

| ID | 要件 |
|---|---|
| FR-AUTH-1 | `POST /v1/auth/apple` は Apple の JWKS で identity token の署名・`iss`・`aud`・`exp` を検証する |
| FR-AUTH-2 | 検証済み `sub` で `users` を find-or-create し、同一トランザクションで `profiles`（`account_id` 採番込み）と `entitlements(plan='free')` を作成する |
| FR-AUTH-3 | access JWT（HS256・`sub` にユーザーID・既定 3600 秒）と refresh token（opaque 32B・sha256 保存・既定 30 日）を返す |
| FR-AUTH-4 | `POST /v1/auth/refresh` は refresh を回転させ、新しい access + refresh を返す。旧 refresh は `revoked_at` を立てる |
| FR-AUTH-5 | `POST /v1/auth/logout` は提示された refresh を失効させ 204 を返す。未知・失効済みでも 204（冪等） |
| FR-AUTH-6 | `AuthGuard` を `APP_GUARD` としてグローバル登録し、`@Public()` の付いたハンドラ/クラスのみ素通しする |
| FR-AUTH-7 | 検証済みユーザーIDは `req.user.id` に載せ、`@CurrentUser()` デコレータで取得する。**クライアントから `owner_id` を受け取らない** |
| FR-AUTH-8 | Apple から返る email は初回のみ `users.email` に保存する（2回目以降 Apple は返さないため上書きしない） |

### 2.2 me（プロフィール / アカウント）

| ID | 要件 |
|---|---|
| FR-ME-1 | `GET /v1/me` は user / profile / entitlement を1レスポンスで返す |
| FR-ME-2 | `PATCH /v1/me` は `username` / `app_display_name` / `theme_color` / `display_name` / `locale` / `timezone` / `onboarded_at` のみ更新できる |
| FR-ME-3 | `account_id` はサーバー生成・読み取り専用。`PATCH` で送られても無視せず `VALIDATION_ERROR` 400 にする（黙殺しない） |
| FR-ME-4 | `theme_color` は `^#[0-9A-Fa-f]{6}$` に一致しない場合 400（docs/03 §4.2 の CHECK と同じ制約をアプリ層でも掛ける） |
| FR-ME-5 | `entitlement` はレスポンスに含めるが、本モジュールから**書き込まない**（ADR-002） |

### 2.3 identities（名義）

| ID | 要件 |
|---|---|
| FR-ID-1 | `GET/POST /v1/identities`・`GET/PATCH/DELETE /v1/identities/:id` を提供する |
| FR-ID-2 | 全操作で `owner_id = currentUser.id` を強制する。他人の id を指定した場合は `NOT_FOUND` 404（`FORBIDDEN` にしない — 存在漏洩を避ける） |
| FR-ID-3 | `id` はクライアント発行 UUID を受理する。既存 id の再 POST は `CONFLICT` 409 |
| FR-ID-4 | 作成時に `entitlements` を見て上限を判定する。`free`: `3 + (bonus_expires_at > now() ? bonus_identity_slots : 0)`、`plus`（有効 or 猶予中）: 無制限。超過は `PLAN_LIMIT_IDENTITY` 403 + `details: { limit, current }` |
| FR-ID-5 | 上限カウントは `deleted_at is null` のみ（docs/03 §5） |
| FR-ID-6 | `DELETE` はソフトデリート（`deleted_at = now()`）。物理削除しない |
| FR-ID-7 | `relation` は `self\|family\|friend\|other` のみ受理。未知値は 400（黙って `other` に落とさない — BE-2） |
| FR-ID-8 | `history_visible` の既定は `false`（共有はオプトイン） |
| FR-ID-9 | `IdentitiesService.assertOwned(userId, id, tx?)` を公開し、memberships / applications から親所有者検証に再利用する |

### 2.4 memberships（FC会員情報）

| ID | 要件 |
|---|---|
| FR-MB-1 | `GET/POST /v1/memberships`（GET は `?identity_id=` で絞込）・`GET/PATCH/DELETE /v1/memberships/:id` |
| FR-MB-2 | 作成・更新時に親 `identity` の所有者を検証する。他人の identity 配下には作れない（404） |
| FR-MB-3 | `owner_id` は親 identity から継承してサーバーが設定する（docs/03 §4.5 の `trg_inherit_owner` 相当をアプリ層で実装） |
| FR-MB-4 | 会員番号の**平文を受理しない**。`member_no_last4` のみ（4文字以内・数字/英数）。`member_no` 等の平文フィールドが来たら 400 |
| FR-MB-5 | `fee_yen` は 0〜1,000,000。`renewal_on` は `YYYY-MM-DD` |
| FR-MB-6 | `DELETE` はソフトデリート |

### 2.5 tours / events / applications / companions

| ID | 要件 |
|---|---|
| FR-AP-1 | `POST /v1/applications` は**単一トランザクション**で tour を find-or-create、event を upsert、application + companions を作成する |
| FR-AP-2 | tour の find-or-create キーは `(owner_id, name)`。ソフトデリート済みの同名 tour がある場合は `deleted_at = null` に復活させて再利用する（`@@unique([ownerId, name])` は部分 unique にできないため） |
| FR-AP-3 | `rep_identity_id` は自分の未削除 identity であることを検証する。不正なら 404 |
| FR-AP-4 | `rep_membership_id`（任意）は自分の未削除 membership かつ `identity_id = rep_identity_id` であることを検証する |
| FR-AP-5 | `companions` は **最大3件**（docs/10 M10）。超過は `VALIDATION_ERROR` 400 |
| FR-AP-6 | `companions[].identity_id` は null 可（未登録の同行者）。非 null なら自分の identity であることを検証する |
| FR-AP-7 | `status` は `draft\|applied\|won\|lost\|cancelled` のみ。未知値は 400。省略時は `applied` |
| FR-AP-8 | `PATCH /v1/applications/:id` で `companions` を渡した場合は**全置換**（渡された配列に無い既存 companion はソフトデリート）。渡されなければ変更しない |
| FR-AP-9 | `GET /v1/applications` は `status` / `tour_id` / `event_id` で絞込、`limit` + `cursor`（`updated_at` ベース）でページング。オフセットは使わない |
| FR-AP-10 | `GET/PATCH/DELETE /v1/tours/:id`・`GET /v1/tours` を提供する。`DELETE` はソフトデリートで、配下 events / applications は**連鎖ソフトデリートしない**（Q: 下記 制約 C4） |
| FR-AP-11 | `GET /v1/events?tour_id=`・`GET/PATCH/DELETE /v1/events/:id` を提供する（主経路は applications 経由の find-or-create） |
| FR-AP-12 | `GET /v1/tours/:id/matrix` は docs/04 §3.5 の形で返す。実装は DB ビューではなく `TourMatrixService`（Prisma クエリ） |
| FR-AP-13 | 同行者の表示名は `identity_id` があればその現在の `display_name`、無ければ保存時の `display_name`（docs/03 §4.8） |

### 2.6 shares / public

| ID | 要件 |
|---|---|
| FR-SH-1 | `POST /v1/shares` は 32 byte ランダムトークンを生成し、`sha256` hex のみ DB に保存する。**生トークンはこのレスポンスでのみ返す** |
| FR-SH-2 | `scope_type=tour` は `scope_id` 必須かつ自分の tour であることを検証する。`identity_summary` は `scope_id` を受け付けない（送られたら 400） |
| FR-SH-3 | Free プランは有効なリンク 1 本まで。超過は `PLAN_LIMIT_SHARE` 403 |
| FR-SH-4 | `expires_at` 省略時は +30 日。指定時の上限は +365 日 |
| FR-SH-5 | `shared_with_account_ids` は記録用メタとして保存するが、公開レスポンスには含めない |
| FR-SH-6 | `GET /v1/shares` は自分のリンク一覧を返す。`token_hash` も生トークンも返さない |
| FR-SH-7 | `DELETE /v1/shares/:id` は `revoked_at` を立てて 204。冪等 |
| FR-SH-8 | `GET /public/shares/:token` は `@Public()`。`sha256(token)` で照合し、`revoked_at is null` かつ未期限切れのときのみ 200。それ以外は一律 `SHARE_INVALID` 404（「失効済み」と「存在しない」を区別しない） |
| FR-SH-9 | 公開レスポンスは `history_visible = false` の名義について `rep_name` を `"非公開の名義"` に置換し、`seat` を `null` にする（docs/03 §6.5 / docs/04 §3.7） |
| FR-SH-10 | 公開レスポンスに会員番号・`owner_id`・`account_id`・内部 UUID のうち不要なものを含めない |
| FR-SH-11 | 有効な閲覧のたびに `view_count` を +1、`last_viewed_at` を更新する。カウント更新の失敗でレスポンスを 500 にしない |

---

## 3. 非機能要件

| ID | 要件 |
|---|---|
| NFR-1 | 全エラーレスポンスは docs/04 §6 の形（`{ code, message, details?, request_id }`）。未知例外は `INTERNAL` 500 でスタックはログのみ |
| NFR-2 | JSON は snake_case。変換はモジュールごとの手書き presenter（Q10） |
| NFR-3 | レイヤは Controller → UseCase → Service → Prisma。Controller / UseCase から Prisma を直接叩かない（ADR-009 / BE-3） |
| NFR-4 | 単純 CRUD は UseCase 省略可。`auth` / `applications`（TX）/ `shares` は UseCase 必須 |
| NFR-5 | 秘密情報（`JWT_ACCESS_SECRET` / `APPLE_CLIENT_ID` / `SHARE_BASE_URL` 等）は `@nestjs/config` 経由。ハードコード禁止 |
| NFR-6 | 振る舞いを持つ全ユースケースに `*.spec.ts`（`src/` 配下）。外部通信（Apple JWKS）と Prisma はモックし、テストに DB / ネットワークを要求しない |
| NFR-7 | 検証ゲート: `npx tsc --noEmit` / `npm test` / `npm run build` がすべてクリーン（ルート `CLAUDE.md`） |
| NFR-8 | ログに identity token / refresh token / 生共有トークン / 会員番号を出力しない |

---

## 4. 制約・設計判断

| # | 判断 | 却下案と理由 |
|---|---|---|
| C1 | 認可の正は Service 層（`ownerId` 付与）。RLS は導入しない | RLS: ADR-002 で Phase 1 必須外。NestJS が唯一の DB クライアントであり二重管理になる |
| C2 | 集計は DB ビューではなく Prisma クエリ（`TourMatrixService`） | DB ビュー（`v_tour_matrix`）: `prisma db push` はビューを管理せず、`schema.prisma` の正と DDL の正が二重化する。docs/09 1-5 でビュー方式を再検討する余地は残す |
| C3 | `member_no_cipher` は今回作らない | 先に列を切る案: docs/02 Q1（鍵の置き場所）未決のまま bytea 列を切ると鍵方式決定時に移行が発生する |
| C4 | tour / event のソフトデリートは**連鎖させない**（配下 application は残る） | 連鎖ソフトデリート案: 同期（Phase 1 の 1-3）で「サーバー起点の一括削除」をクライアントへ伝播させる仕組みが未実装。今は削除の影響範囲を最小に保つ。ツアー表からは `deleted_at is null` の event のみ引く |
| C5 | `NOT_FOUND` 404 を「他人のリソース」にも使う | 403 案: 存在の有無が漏れる（BE-4） |
| C6 | `app.module.ts` と `schema.prisma` は**基盤タスクでのみ編集**し、以降のタスクは触らない | 各タスクで追記する案: 並列実行時に確実に衝突する（rule 03） |
| C7 | Apple JWKS 取得は `AppleJwksClient` として DI し、テストでモック | 直接 fetch 案: テストがネットワーク依存になり CI で不安定化 |

---

## 5. エッジケース（実装で必ず考慮する）

| # | ケース | 期待 |
|---|---|---|
| E-1 | 同一 `id` の POST を2回（オフライン再送） | 2回目は 409 `CONFLICT`。データを壊さない |
| E-2 | ソフトデリート済み tour と同名の tour 名で申込作成 | 既存行を `deleted_at = null` で復活し再利用（FR-AP-2） |
| E-3 | 名義を上限まで作った後に1件削除 → 再作成 | 成功する（削除分は上限にカウントしない） |
| E-4 | `bonus_expires_at` が過去のボーナス枠 | 加算しない |
| E-5 | `entitlements` 行が存在しないユーザー | `free` / 上限 3 として扱う（`coalesce` 相当）。500 にしない |
| E-6 | companions 0件の申込 | 正常。空配列を返す |
| E-7 | companions に同一 `identity_id` を重複指定 | 400 `VALIDATION_ERROR` |
| E-8 | 共有トークンの `expires_at` ちょうど（境界） | `expires_at > now()` を有効とする（`>=` ではない。境界時刻は無効） |
| E-9 | 失効済み共有リンクへのアクセス | 404 `SHARE_INVALID`。`view_count` は増やさない |
| E-10 | 対象 tour に application が0件の共有リンク閲覧 | 200 で `items: []`（404 にしない） |
| E-11 | `history_visible=false` の名義しか含まないツアーの共有 | 200。全行 `rep_name = "非公開の名義"` / `seat = null` |
| E-12 | 日付 `2026-08-20` を Asia/Tokyo 環境で保存・読み出し | 往復して `2026-08-20`（前日にずれない） |
| E-13 | refresh token を同時に2回使用（競合） | 先勝ち。後発は 401 `AUTH_REFRESH_INVALID` |
| E-14 | Apple identity token の `aud` が別アプリ | 401 `AUTH_APPLE_INVALID` |
| E-15 | `account_id` 採番衝突 | 最大5回リトライ。それでも衝突なら 500 |
| E-16 | `PATCH /v1/applications/:id` で companions を空配列指定 | 既存 companions を全てソフトデリート |
| E-17 | 他ユーザーの identity を `rep_identity_id` に指定 | 404（作成されない・TX ロールバック） |
| E-18 | `limit` に 0 や 1000 | 1〜200 にクランプまたは 400（契約で確定 → `api-contract.md`） |

---

## 6. 影響範囲

| 層 | 対象 |
|---|---|
| DB | `apps/api/prisma/schema.prisma`（`RefreshToken` 追加 + Q1 のカラム追加）→ `cd apps/api && npx prisma db push` |
| BE | `apps/api/package.json`（依存追加）、`src/main.ts`、`src/app.module.ts`、`src/common/`、`src/auth/`、`src/me/`、`src/entitlements/`、`src/identities/`、`src/memberships/`、`src/tours/`、`src/events/`、`src/applications/`、`src/shares/`、`src/public/` |
| iOS | **本計画では変更しない**。`Packages/Network`（未作成）・`Packages/Domain`・`Packages/Features` の追従は別計画（`questions-requirements.md` E1〜E7 が申し送り） |
| docs | 実装確定後に `docs/04-api.md` を実装に合わせて更新（`/v1/me`・`GET /v1/shares`・`DELETE /v1/shares/:id`・スキーマ差分）。`docs/02-architecture.md` §7 Q4（refresh 保存方式）を「決定済み」に更新 |
| インフラ | `apps/api/.env.example` に `JWT_ACCESS_SECRET` / `JWT_ACCESS_TTL` / `REFRESH_TTL_DAYS` / `APPLE_CLIENT_ID` / `APPLE_ISSUER` / `APPLE_JWKS_URL` / `SHARE_BASE_URL` を追記 |
