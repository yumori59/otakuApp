# questions-requirements — backend-domain-modules

対象: NestJS ドメインモジュール一式（auth / me / identities / memberships / tours・events・applications / shares・public）

各項目は **planner 推奨案を `[Assumed]` として暫定確定**し、その前提で `requirements.md` / `api-contract.md` / `plan.md` を作成している。
実装着手前に `[Answer]:` を埋めること。**推奨案と異なる回答が入った箇所は requirements と契約を先に更新してから実装する。**

---

## A. Prisma スキーマの不足（docs/03・04 と `schema.prisma` の矛盾）

### Q1. docs/04 のリクエスト/レスポンスに出てくるが `schema.prisma` に無いカラムを追加するか

docs/04 §3.3・§3.4・§3.5 は以下を前提にしているが、現行 `apps/api/prisma/schema.prisma` に存在しない。

| 対象 | 欠落カラム | docs 出典 |
|---|---|---|
| `Event` | `starts_at` | 04 §3.4 req / 03 §4.6 |
| `Application` | `rep_membership_id` / `round_name` / `ticket_count` / `price_yen` | 04 §3.4 req・§3.5 matrix / 03 §4.7 |
| `Membership` | `rank` / `auto_renew` / `member_no_cipher` / `fan_club_id` | 04 §3.3 req / 03 §4.5 |
| `Event` | `venue_id` | 03 §4.6 |
| （認証） | refresh token 永続化テーブルが無い | 04 §3.1 / 02 Q4 |

`[Assumed]` 次の方針で追加・不採用を切り分ける。

- **追加する**: `Event.starts_at`、`Application.rep_membership_id` / `round_name` / `ticket_count` / `price_yen`、`Membership.rank` / `auto_renew`、新規 `RefreshToken` モデル
  - 理由: docs/04 の契約に既に載っており、後から足すと iOS 側のパース契約変更（IOS-2）になる
- **追加しない**: `Membership.member_no_cipher`
  - 理由: docs/02 §7 Q1（暗号鍵の置き場所）が未決。鍵方式が決まる前に bytea 列を切ると移行が発生する。Phase 1 は `member_no_last4` のみ受理し、平文会員番号は受理しない（docs/04 §3.3 と整合）
- **追加しない**: `Membership.fan_club_id` / `Event.venue_id` および `artists` / `fan_clubs` / `venues` マスタ3表
  - 理由: マスタ整備は docs/09 の Phase 3（3-3 公演情報マスタと自動補完）。Phase 1 は `*_name_raw` のみで docs/03 §4.3 の「初期はマスタが空でも動作する」に合致する
- **追加しない**: `Application.seat_block` / `seat_row` / `seat_no`
  - 理由: docs/03 §4.7 で「将来の統計用」と明記。Phase 1 の UI（モック）は `seat_raw` のみ

`[Answer]`:

### Q2. refresh token の保存方式（docs/02 §7 Q4 の未決事項）

`[Assumed]` **DB テーブル + 回転式 opaque token** を採用する。

- `refresh_tokens(id, user_id, token_hash, expires_at, revoked_at, replaced_by, created_at)`
- 生トークンは 32 byte ランダムの base64url。DB は `sha256` hex のみ保持（share_links と同方式）
- `POST /v1/auth/refresh` は旧トークンを `revoked_at` にし新トークンを発行（回転）
- 失効済みトークンの再提示は `AUTH_REFRESH_INVALID` 401（再利用検知時に当該ユーザーの全 refresh を失効させるかは Q2-b）

`[Answer]`:

### Q2-b. refresh token 再利用検知時に同一ユーザーの全トークンを失効させるか

`[Assumed]` **Phase 1 では行わない**（該当トークンのみ 401）。理由: 正常系でも通信断による二重送信が起きうる。全失効は誤ログアウトのユーザー影響が大きい。

`[Answer]`:

---

## B. docs/04 に契約が無いエンドポイント

### Q3. プロフィール / アカウント API のパスと形

docs/04 にプロフィール取得・更新のエンドポイント記載が無い（`profiles.account_id` / `username` / `app_display_name` / `theme_color` は docs/10 M3・M4 で必須）。

`[Assumed]`

- `GET /v1/me` → `{ user, profile, entitlement }` を1往復で返す
- `PATCH /v1/me` → `username` / `app_display_name` / `theme_color` / `display_name` / `locale` / `timezone` / `onboarded_at` のみ更新可
- `account_id` は **サーバー生成・読み取り専用**（クライアントから変更不可）
- 生成タイミングは `POST /v1/auth/apple` の初回ユーザー作成時。形式は `ACC-` + 大文字16進6桁（例 `ACC-3F9A21`）。衝突時は最大5回再生成し、それでも衝突したら `INTERNAL` 500
  - 注: iOS `AuthStore.generateAccountID`（`meigicho/Packages/Domain/Sources/Domain/AuthStore.swift:22`）はメールからのクライアント生成モック。**サーバー生成に置き換える**（iOS 側の追従が必要）

`[Answer]`:

### Q4. 共有リンクの一覧・失効の契約

docs/04 §3.7 は発行（`POST /v1/shares`）と公開解決（`GET /public/shares/:token`）のみ定義。失効操作は docs/09 1-6 に「失効操作」とあるが契約が無い。

`[Assumed]`

- `GET /v1/shares` → 自分のリンク一覧（生トークンは返さない。`view_count` / `last_viewed_at` / `revoked_at` を含む）
- `DELETE /v1/shares/:id` → 204。物理削除せず `revoked_at = now()`（冪等: 失効済みでも 204）
- 生トークンの再取得手段は**提供しない**（docs/04「生tokenは一度だけ」）

`[Answer]`:

### Q5. `POST /v1/shares` で `shared_with_account_ids` を受けるか

docs/10 M8 でモックは共有前にアカウントID入力モーダルを出す。`schema.prisma` に列はあるが docs/04 §3.7 のリクエスト例に無い。

`[Assumed]` **受ける**。`string[]`（最大20件・各 `^ACC-[0-9A-F]{6}$`）。**ACL ではなく記録用メタ**であり、`GET /public/shares/:token` のレスポンスには**含めない**（閲覧者に他人のアカウントIDを見せない）。所有者向け `GET /v1/shares` にのみ含める。

`[Answer]`:

### Q6. `share_links.scope_type` の Phase 1 対応範囲

docs/03 §4.9 の CHECK は `('tour','identity_summary')`。

`[Assumed]` **両方を Phase 1 で実装する**。`identity_summary` は `scope_id = null`（所有者の全名義サマリ）。docs/03 §6.5 の `rpc_resolve_share` が両方を組み立てており、payload 定義が既に確定しているため追加コストが小さい。

`[Answer]`:

### Q7. Free プランの共有リンク上限（`PLAN_LIMIT_SHARE`）

docs/04 §3.7「Freeは1本」。

`[Assumed]` **「有効なリンク（`revoked_at is null` かつ（`expires_at is null` または `expires_at > now()`））が1本」** を Free の上限とする。失効・期限切れは上限にカウントしない（identities のソフトデリート除外と同じ考え方 = docs/03 §5）。Plus は無制限。

`[Answer]`:

### Q8. 共有リンクの既定有効期限

docs/09 7.1 L3 の緩和策に「有効期限30日の既定」。docs/04 §3.7 の req は `expires_at` を明示指定。

`[Assumed]` `expires_at` 省略時は **発行時刻 + 30日** をサーバーが設定する。明示指定時は最大 **発行時刻 + 365日** まで（超過は `VALIDATION_ERROR` 400）。

`[Answer]`:

---

## C. 横断的な実装方針

### Q9. `/v1` グローバルプレフィックスと除外パス

現行 `apps/api/src/main.ts:5` はプレフィックス未設定、`/health` `/readyz` を素で公開している。

`[Assumed]` `app.setGlobalPrefix('v1', { exclude: ['health', 'readyz', 'public/shares/:token'] })`。既存 `/health` `/readyz` の URL は変えない（`make health` / Cloud Run のヘルスチェックが依存）。

`[Answer]`:

### Q10. JSON の snake_case 化の方式

docs/04 §1.2「JSON は snake_case（DB列と一致）」。Prisma の TS フィールドは camelCase（`@map` 済み）。

`[Assumed]` **モジュールごとに手書きの presenter 関数**（`identities/identities.presenter.ts` 等）で Prisma モデル → レスポンス DTO に変換する。

- 却下: グローバル `camelCase→snake_case` インターセプタ — 返してはいけない列（`token_hash`・`member_no_cipher`・他人の `owner_id`）まで機械的に露出させる事故が起きやすく、共有 API のマスキング（docs/03 §6.5）と両立しない
- 却下: Prisma の `@@map` だけに頼る — TS 型は camelCase のままなので効果なし

`[Answer]`:

### Q11. 日付（`@db.Date`）の入出力変換

`[Assumed]` DTO は `YYYY-MM-DD` 文字列で受け、`common/date.util.ts` で `new Date(`${s}T00:00:00.000Z`)` に変換して保存。レスポンスは `toISOString().slice(0,10)` で戻す。ローカルタイムゾーン（Asia/Tokyo）依存の `new Date('2026-08-20')` 解釈揺れを持ち込まない。

`[Answer]`:

### Q12. UUID バリデーション（BE-1）

`[Assumed]` `@IsUUID()`（バージョン無指定）を使う。**`@IsUUID('4')` は使わない** — ID はクライアント発行 UUID v7（docs/03 P1）で、v4 検証だと全 POST が 400 になる。

`[Answer]`:

### Q13. Apple identity token 検証の設定と nonce

`[Assumed]`

- 環境変数: `APPLE_CLIENT_ID`（iOS bundle id）、`APPLE_ISSUER=https://appleid.apple.com`、`APPLE_JWKS_URL=https://appleid.apple.com/auth/keys`
- 検証: 署名（JWKS・kid 一致）/ `iss` / `aud` / `exp` / `nbf`
- `nonce`: **リクエストに含まれていれば検証する。含まれていなければ検証しない**（docs/04 §3.1 の req が `"nonce": "optional"`）
- JWKS は `AppleJwksClient` として DI 可能な形にし、キャッシュ TTL 10分。テストではモックに差し替える（外部通信をテストに持ち込まない）

`[Answer]`:

---

## D. スコープ境界

### Q14. 今回スコープ外とする範囲の確認

`[Assumed]` 以下は**本計画のスコープ外**。着手前に別計画を立てる。

| 対象 | docs 出典 | 除外理由 |
|---|---|---|
| `sync/`（pull / push・LWW） | 04 §3.6・§4 | docs/09 1-3（8人日・Phase 1 最大の難所）。単独計画が必要 |
| `billing/`（RevenueCat Webhook） | 04 §3.8 | docs/09 1-9。`entitlements` の**書き込み**は本計画で一切行わない（ADR-002） |
| `home/summary` / `stats/identities` | 04 §3.5 | docs/09 1-5。集計ビュー（`v_identity_stats` / `v_upcoming_renewals`）の実装方針（DB ビュー or Prisma クエリ）が未決 |
| `device_tokens`（APNs） | 04 §3.8 / 03 §4.10 | docs/09 1-12 |
| Next.js 共有 Web | 04 §5 | docs/09 1-7。本計画は `GET /public/shares/:token` の API まで |
| Google / メール+パスワード認証 | 10 §2 | 「任意」。Apple 必須のみ実装 |
| RLS / pgTAP | 03 §6 | ADR-002 で Phase 1 必須ではない |
| iOS 側の追従実装 | 05 | 別セッションで `swift-developer` に委譲。本計画は API 契約の確定まで |

`[Answer]`:

### Q15. `GET /v1/tours/:id/matrix` を今回に含めるか

docs/04 §3.5 は `v_tour_matrix` ビュー前提で定義。Q14 で集計系を除外したが、matrix は **`GET /public/shares/:token`（scope_type=tour）のペイロード組立と同一ロジック**であり、共有機能の実装過程で必然的に作られる。

`[Assumed]` **含める**。ただし DB ビューは作らず、`TourMatrixService.build(ownerId, tourId)` として Prisma クエリで実装し、shares の公開ペイロードは同 Service の結果に**マスキングを適用**して組み立てる（ロジック二重化の回避）。

`[Answer]`:

---

## E. 既存 iOS 実装との差分（契約確定にあたっての注意）

回答不要。実装エージェントへの申し送りとして記録する（IOS-2）。

| # | 内容 | 出典 |
|---|---|---|
| E1 | iOS `Membership` は `memberNo` を**平文 String** で保持している | `meigicho/Packages/Domain/Sources/Domain/Models/Models.swift:6` — BE は平文を受理しない。iOS 側で下4桁抽出が必要 |
| E2 | iOS `Membership.renewalOn` / `annualFee` が非 Optional | 同 :7-8 — BE は `renewal_on` / `fee_yen` とも nullable |
| E3 | iOS `ApplicationEntry` は `tourName` / `eventName` / `venueName` / `artistName` を**文字列でフラットに保持**（Tour / Event の正規化なし） | 同 :62-67 — BE は `tours` / `events` に正規化。iOS 側にマッピングが必要 |
| E4 | iOS `Identity.historyVisible` の既定が `true` | 同 :44 — DB 既定は `false`（docs/03 §4.4「共有はオプトイン」）。BE 既定は `false` を維持し、iOS 側を要修正 |
| E5 | iOS `AuthStore` は Google / メールのみでモック実装 | `AuthStore.swift:33-56` — Sign in with Apple への差し替えが必要 |
| E6 | iOS `TourShareStore` は UserDefaults にローカル保存する擬似共有 | `TourShareStore.swift:56-88` — `POST /v1/shares` への差し替えが必要 |
| E7 | `ApplicationStatus` / `Relation` の enum 値は BE と**一致している**（`draft/applied/won/lost/cancelled`、`self/family/friend/other`） | `Enums/AppEnums.swift:3-24` — 変更しないこと（BE-2） |
