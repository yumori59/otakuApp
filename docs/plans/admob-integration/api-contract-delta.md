# API 契約差分 — admob-integration

**この文書が本計画における契約の正。** 実装エージェントはここに書かれたパス・メソッド・JSON キー・enum 値・エラーコードを勝手に変えない。
変更が必要なら実装を止めて planner に差し戻す（`.claude/rules/02-agents.md`）。

ベースは `docs/plans/backend-domain-modules/api-contract.md`（共通規約・エラー envelope）。
本書はそこへの**追記差分**。共通規約（`/v1` プレフィックス・snake_case・Bearer 認証・ISO8601 UTC・UUID）は継承する。

---

## 0. 変更サマリ

| # | 種別 | 対象 |
|---|---|---|
| 1 | DB | `entitlements` に 2 カラム追加 |
| 2 | DB | `rewarded_ad_claims` テーブル新設 |
| 3 | API 変更 | `GET /v1/me` の `entitlement` に 3 キー追加 |
| 4 | API 新設 | `POST /v1/rewards/claims` |
| 5 | API 新設 | `GET /v1/rewards/claims/:claim_id` |
| 6 | API 新設 | `GET /v1/webhooks/admob-ssv`（`@Public()` / AdMob からのコールバック） |
| 7 | エラーコード | 3 種追加 |
| 8 | 環境変数 | 2 種追加 |
| 9 | 既存改修 | `DELETE /v1/me` の削除順に `rewarded_ad_claims` を追加 |

---

## 1. DB 差分（`apps/api/prisma/schema.prisma`）

### 1.1 `Entitlement` へのカラム追加

`docs/07-monetization.md:417-425` の DDL 案に対応する残り 2 カラム。既存の `bonusIdentitySlots` / `bonusExpiresAt` は**既に存在するので触らない**。

```prisma
model Entitlement {
  // ... 既存フィールドは変更しない（schema.prisma:85-100）
  rewardedViewsMonth   Int       @default(0) @map("rewarded_views_month") @db.SmallInt
  rewardedViewsResetAt DateTime? @map("rewarded_views_reset_at") @db.Date
}
```

- `rewardedViewsResetAt` は **JST の当月 1 日**（Q8）。`null` は「まだ 1 度も視聴していない」。
- 読み取り時に `rewardedViewsResetAt` が JST 当月 1 日より前なら **視聴回数 0 として扱う**（バッチでのリセットは行わない）。

### 1.2 `RewardedAdClaim` 新設

```prisma
model RewardedAdClaim {
  id            String    @id @db.Uuid
  userId        String    @map("user_id") @db.Uuid
  placement     String    @default("identity_slot")
  status        String    @default("pending")
  transactionId String?   @unique @map("transaction_id")
  createdAt     DateTime  @default(now()) @map("created_at") @db.Timestamptz(6)
  expiresAt     DateTime  @map("expires_at") @db.Timestamptz(6)
  grantedAt     DateTime? @map("granted_at") @db.Timestamptz(6)
  rejectReason  String?   @map("reject_reason")

  user User @relation(fields: [userId], references: [id], onDelete: Cascade)

  @@index([userId, createdAt], map: "rewarded_ad_claims_user_created_idx")
  @@map("rewarded_ad_claims")
}
```

`User` モデルに `rewardedAdClaims RewardedAdClaim[]` のリレーションを追加すること。

| 項目 | 値 |
|---|---|
| `id` | **サーバー生成 UUID v4**。AdMob SSV の `custom_data` に載せる（クライアント発行にしない — 予測されると他人の claim を消費できてしまう） |
| `placement` enum | `"identity_slot"` のみ（将来拡張用。未知値は 400） |
| `status` enum | `"pending"` / `"granted"` / `"rejected"` / `"expired"` |
| `transactionId` | AdMob SSV の `transaction_id`。**UNIQUE でリプレイ防止**。`pending` の間は `null` |
| `expiresAt` | `createdAt + 15 分`。超過後の SSV は付与せず `expired` にする |
| `rejectReason` | `"plan_limit"` / `"slot_active"` / `"plus"` / `"expired"` / `"user_mismatch"` / `"signature"` |

### 1.3 `DELETE /v1/me` の削除順

`apps/api/src/me/me.service.ts:149-163` のトランザクションに追加する。位置は **`entitlement.deleteMany` の直前**（`user` への FK を持つため `user.delete` より前ならどこでもよいが、entitlements と隣接させる）。

```ts
await tx.rewardedAdClaim.deleteMany({ where: { userId } });
await tx.entitlement.deleteMany({ where: { userId } });
```

---

## 2. `GET /v1/me` — `entitlement` に 3 キー追加

**既存キーは一切変更しない。** 追加のみ。

```jsonc
{
  "user": { /* 変更なし */ },
  "profile": { /* 変更なし */ },
  "entitlement": {
    "plan": "free",
    "expires_at": null,
    "in_grace_period": false,
    "bonus_identity_slots": 0,
    "bonus_expires_at": null,
    "identity_limit": 3,
    "share_limit": 1,

    // ↓ 追加
    "rewarded_views_this_month": 0,          // 0 以上の整数。JST 当月の視聴（付与）回数
    "rewarded_views_limit": 2,               // 固定 2。plan="plus" のときは 0
    "rewarded_views_reset_at": "2026-09-01"  // 次にカウンタが 0 に戻る日（JST 月初）。YYYY-MM-DD
  }
}
```

| キー | 型 | 備考 |
|---|---|---|
| `rewarded_views_this_month` | `number` | `rewarded_views_reset_at` が当月より前なら **0 を返す**（DB 値をそのまま返さない） |
| `rewarded_views_limit` | `number` | `plan === "plus"` のとき **0**（導線を出さないためのヒント） |
| `rewarded_views_reset_at` | `string` (`YYYY-MM-DD`) | **常に翌月 1 日（JST）**。null にしない |

**iOS 追従（IOS-2）**: `meigicho/Packages/Network/Sources/Network/DTO/MeDTO.swift` の `MeEntitlementDTO` と `meigicho/Packages/Domain/Sources/Domain/Models/AccountModels.swift` の `Entitlement` に 3 プロパティを追加する。`Entitlement.init` の既定値は `rewardedViewsThisMonth: 0` / `rewardedViewsLimit: 2` / `rewardedViewsResetAt: nil`。

---

## 3. `POST /v1/rewards/claims` — リワード視聴の事前登録（新設）

リワード動画を**表示する前**に呼ぶ。サーバー側で資格を判定し、SSV の `custom_data` に載せる claim を発行する。

### Request

```
POST /v1/rewards/claims
Authorization: Bearer <access_token>
Content-Type: application/json
```

```json
{ "placement": "identity_slot" }
```

| フィールド | 型 | 必須 | 検証 |
|---|---|---|---|
| `placement` | `string` | 任意（既定 `"identity_slot"`） | `"identity_slot"` のみ許容。**未知値は 400 `VALIDATION_ERROR`**（BE-2: 黙ってフォールバックしない） |

### Response `201 Created`

```json
{
  "claim_id": "9c8f1c2a-4b1e-4c90-9d2a-1a2b3c4d5e6f",
  "custom_data": "9c8f1c2a-4b1e-4c90-9d2a-1a2b3c4d5e6f",
  "user_identifier": "018f3c2a-7b1e-7c90-9d2a-1a2b3c4d5e6f",
  "expires_at": "2026-08-07T12:15:00.000Z",
  "remaining_views_this_month": 1,
  "reward_bonus_slots": 1,
  "reward_duration_days": 30
}
```

| キー | 意味 |
|---|---|
| `custom_data` | iOS が `GADServerSideVerificationOptions.customRewardString` に設定する値（= `claim_id`） |
| `user_identifier` | iOS が `GADServerSideVerificationOptions.userIdentifier` に設定する値（= 認証中の `user_id`） |
| `remaining_views_this_month` | この claim を**発行した後**の残り回数（0 or 1） |
| `reward_bonus_slots` / `reward_duration_days` | UI 文言用。固定 `1` / `30`（Q3 確定後に `reward_bonus_slots` を再確認） |

### エラー

| HTTP | code | 条件 | details |
|---|---|---|---|
| 400 | `VALIDATION_ERROR` | 未知の `placement` | — |
| 401 | `UNAUTHENTICATED` | Bearer 欠落・不正 | — |
| 403 | `PLAN_LIMIT_REWARDED_VIEWS` | JST 当月の視聴回数が 2 に達している | `{ "limit": 2, "used": 2, "reset_at": "2026-09-01" }` |
| 409 | `REWARD_SLOT_ACTIVE` | 有効なボーナス枠が残っており、残り **7 日超** | `{ "bonus_expires_at": "2026-09-01T00:00:00.000Z" }` |
| 409 | `REWARD_NOT_APPLICABLE` | `plan === "plus"` または `in_grace_period === true` | `{ "plan": "plus" }` |
| 503 | `SERVICE_UNAVAILABLE` | `ADMOB_SSV_ENABLED` が false | — |

**同一ユーザーの `pending` claim が既にある場合**: 古い方を `expired` にしてから新規発行する（連打で claim が溜まるのを防ぐ）。エラーにはしない。

**F6-7（異常検知ログ）**: JST 当日の claim 作成が 3 件目以降になったら `Logger.warn` に `userId` と件数を出す。**ブロックはしない**（`docs/07:435` は「ログに記録し異常検知の対象にする」であって拒否ではない）。

---

## 4. `GET /v1/rewards/claims/:claim_id` — 付与状態のポーリング（新設）

### Request

```
GET /v1/rewards/claims/9c8f1c2a-4b1e-4c90-9d2a-1a2b3c4d5e6f
Authorization: Bearer <access_token>
```

`:claim_id` は `@IsUUID()` 相当の検証のみ（バージョンは検証しない — 共通規約）。

### Response `200 OK`

```json
{
  "claim_id": "9c8f1c2a-4b1e-4c90-9d2a-1a2b3c4d5e6f",
  "status": "granted",
  "granted_at": "2026-08-07T12:03:11.000Z",
  "reject_reason": null,
  "bonus_identity_slots": 1,
  "bonus_expires_at": "2026-09-06T12:03:11.000Z",
  "identity_limit": 4
}
```

| キー | 型 | 備考 |
|---|---|---|
| `status` | `"pending" \| "granted" \| "rejected" \| "expired"` | クライアントは未知値を受けたら `pending` 扱いにせず**エラー表示**する |
| `granted_at` | `string \| null` | `granted` のときのみ非 null |
| `reject_reason` | `string \| null` | `rejected` のときのみ非 null。§1.2 の enum |
| `bonus_identity_slots` / `bonus_expires_at` / `identity_limit` | — | 現在の entitlement のスナップショット。`granted` を受けた iOS はここで即座に UI を更新でき、`GET /v1/me` の再取得を待たなくてよい |

**`expiresAt` を過ぎた `pending` は、この GET の中で `expired` に遷移させてから返す**（遅延評価。バッチ不要）。

### エラー

| HTTP | code | 条件 |
|---|---|---|
| 401 | `UNAUTHENTICATED` | Bearer 欠落・不正 |
| 404 | `NOT_FOUND` | claim が存在しない、**または他ユーザーの claim**（BE-4: 403 ではなく 404 で存在を秘匿する。既存モジュールと同じ方針） |

---

## 5. `GET /v1/webhooks/admob-ssv` — AdMob SSV コールバック（新設・`@Public()`）

**メソッドは GET**（AdMob の仕様。POST ではない）。AdMob が管理画面に設定されたコールバック URL へクエリパラメータを付けて GET する。

```
GET /v1/webhooks/admob-ssv?ad_network=5450213213286189855&ad_unit=1234567890&custom_data=9c8f...&key_id=3335741209&reward_amount=1&reward_item=identity_slot&timestamp=1786104191000&transaction_id=1a2b3c...&user_id=018f3c2a-...&signature=MEQCIF...
```

### クエリパラメータ（AdMob が送信。順序は AdMob 任意）

| 名前 | 用途 |
|---|---|
| `ad_network` / `ad_unit` / `reward_amount` / `reward_item` | ログ用。**値による分岐はしない** |
| `custom_data` | `claim_id`（§3 で発行した UUID） |
| `user_id` | iOS が設定した `userIdentifier`（= 認証ユーザーの UUID） |
| `transaction_id` | AdMob 発行の一意 ID。リプレイ防止キー |
| `timestamp` | epoch ミリ秒 |
| `key_id` | 検証に使う Google 公開鍵の ID |
| `signature` | web-safe base64 の ECDSA(P-256, SHA-256) 署名 |

### 【最重要】署名検証の入力文字列

**署名対象は「生のクエリ文字列から `&signature=...` 以降を除いた部分」**。

```
検証対象 = req.originalUrl の "?" の直後から、"&signature=" が現れる直前まで
```

- **`@Query()` でパース済みのオブジェクトから再構築してはいけない。** キー順序と URL エンコードが失われ、署名検証が必ず失敗する。
- 実装は `@Req() req: Request` を受け、`req.originalUrl`（Express）から文字列操作で切り出す。
- `signature` と `key_id` は末尾 2 つで送られてくる前提だが、**`&signature=` の出現位置で切る**実装にすること（`key_id` が後ろに来る）。

### 検証手順（この順序で行う）

1. `ADMOB_SSV_ENABLED` が true でなければ **503**（付与は行わない）
2. 必須パラメータ（`custom_data` / `user_id` / `transaction_id` / `timestamp` / `key_id` / `signature`）の存在確認 → 欠落は **400**
3. `timestamp` が現在時刻から **±60 分**の範囲外 → **401**
4. `key_id` に対応する公開鍵をキャッシュから取得。無ければ `ADMOB_SSV_KEYS_URL` を 1 回だけ再取得（TTL 24 時間、直近 5 分以内に取得済みなら再取得しない）。それでも無ければ **401**
5. ECDSA(P-256, SHA-256) で署名検証（`signature` は web-safe base64 → Buffer、DER 形式）。失敗 → **401**
6. 付与処理（§5.1）

### 付与処理（単一トランザクション）

1. `transaction_id` を UNIQUE で claim に書き込む。**P2002（一意制約違反）ならリプレイなので 200 no-op**（BE-6・既存 `billing.service` の「未知は 200 no-op」方針と同じ）
2. `custom_data` の claim を取得。存在しない → **200 no-op** + `Logger.warn`
3. `claim.userId !== user_id` → `rejected` (`user_mismatch`) にして **401**
4. `claim.status !== "pending"` → **200 no-op**
5. `claim.expiresAt < now` → `expired` にして **200**（付与しない）
6. entitlement を**再検証**（claim 発行時から状況が変わりうる）: `plan === "plus"` → `rejected`(`plus`) / 当月視聴 2 回到達 → `rejected`(`plan_limit`) / ボーナス残り 7 日超 → `rejected`(`slot_active`)。いずれも **200**（AdMob にリトライさせない）
7. 付与:
   - `bonusIdentitySlots = 1`（**加算ではなく 1 に固定** — 同時 1 枠。Q3 確定待ち）
   - `bonusExpiresAt = now + 30 日`
   - `rewardedViewsMonth = (当月なら現在値 else 0) + 1`、`rewardedViewsResetAt = JST 当月 1 日`
   - `claim.status = "granted"`、`claim.grantedAt = now`

### Response

| HTTP | 条件 |
|---|---|
| 200（ボディ空） | 付与成功 / リプレイ / 未知 claim / 期限切れ / 資格喪失（= AdMob にリトライさせたくないすべて） |
| 400 | 必須パラメータ欠落 |
| 401 | 署名不正 / timestamp 範囲外 / 鍵未知 / `user_id` 不一致 |
| 503 | `ADMOB_SSV_ENABLED` が false |

**方針**: 「AdMob 側が悪い（不正リクエスト）」は 4xx、「こちら側で処理済み・処理不要」は 200。これは既存 `apps/api/src/billing/billing.service.ts:38-52`（未知ユーザーは warn + 200）と同じ考え方。

---

## 6. エラーコード追加

`docs/plans/backend-domain-modules/api-contract.md §0` のエラーコード表に追記する。

| code | HTTP | 使う場面 |
|---|---|---|
| `PLAN_LIMIT_REWARDED_VIEWS` | 403 | JST 当月のリワード視聴が上限（2 回）に達している |
| `REWARD_SLOT_ACTIVE` | 409 | 有効なボーナス枠の残りが 7 日超のため再視聴できない |
| `REWARD_NOT_APPLICABLE` | 409 | Plus / grace 中でリワードの対象外 |

既存の `ErrorCode` enum（`apps/api/src/common/`）に 3 値を追加する。既存値は変更しない。

---

## 7. 環境変数追加（`apps/api/.env.example` — **ユーザー対応が必要**）

```
# AdMob SSV（リワード広告のサーバー側検証）。false / 未設定なら /v1/webhooks/admob-ssv は 503、
# POST /v1/rewards/claims も 503 を返す（機能全体が無効）
ADMOB_SSV_ENABLED=false
# Google が公開する検証用公開鍵。通常は既定値のまま
ADMOB_SSV_KEYS_URL=https://www.gstatic.com/admob/reward/verifier-keys.json
```

秘密情報は含まない（Q6）。エージェントは deny 設定で `.env.example` を書けないため、**ユーザーが手動追記する**。

---

## 8. iOS 側の広告ユニット ID 設定（契約ではないが 3 層整合に必要）

`meigicho/project.yml` の `settings.base` に追加し、Info.plist 経由で読む（既存 `REVENUECAT_API_KEY` / `GOOGLE_IOS_CLIENT_ID` と同じパターン）。

```yaml
settings:
  base:
    ADMOB_APP_ID: ""                       # ca-app-pub-XXXX~YYYY。空なら SDK を初期化しない
    ADMOB_UNIT_HOME_NATIVE: ""
    ADMOB_UNIT_IDENTITIES_BANNER: ""
    ADMOB_UNIT_APPLICATIONS_NATIVE: ""
    ADMOB_UNIT_TOURTABLE_BANNER: ""
    ADMOB_UNIT_IDENTITYDETAIL_BANNER: ""
    ADMOB_UNIT_REWARDED: ""
```

- Info.plist の `GADApplicationIdentifier` に `$(ADMOB_APP_ID)` を割り当てる。**空文字のままだと SDK が起動時に例外を投げる仕様があるため、`ADMOB_APP_ID` が空のときは `GADMobileAds.start` を呼ばない**（`AdRendererFactory` が `DisabledAdRenderer` を返す）。
- Debug 構成では Google 公式テストユニット ID を既定値として埋めてよい（実 ID 取得前に開発を進めるため。Q5）。
- **`NSUserTrackingUsageDescription` は追加しない**（`docs/08:511` / Q2）。
